#!/usr/bin/env python3
"""LoRA fine-tune of a cleanup model on a CUDA GPU (12 GB is enough for a 9B model in 4-bit), on the
same chat-format data train/train.sh trains on (`murmur export-training` writes it). For a larger
teacher than the Mac trains comfortably, and for a student distilled from it (generate.py).

  sft.py --model Qwen/Qwen3.5-9B --data DIR (train.jsonl, valid.jsonl) --out RUN [--epochs 2]

Resumable: checkpoints every --save-steps and on SIGTERM; a rerun with the same arguments continues
from the newest checkpoint. RUN/best holds the adapter with the lowest validation loss.
"""
import argparse, json, math, os, signal, sys, time
from pathlib import Path

try:  # optional supervisor hooks (heartbeat, pause, duty cycle); no-ops elsewhere
    import gpujob
except ImportError:
    gpujob = None

_stop = False


def _term(*_):
    global _stop
    _stop = True


def render(tok, messages, add_generation_prompt):
    kw = {"tokenize": False, "add_generation_prompt": add_generation_prompt}
    try:
        return tok.apply_chat_template(messages, enable_thinking=False, **kw)
    except TypeError:
        return tok.apply_chat_template(messages, **kw)


def encode(tok, row, max_len):
    msgs = row["messages"]
    prompt = render(tok, msgs[:-1], True)
    full = render(tok, msgs, False)
    if not full.startswith(prompt):  # templates that rewrite earlier turns: fall back to prompt + answer
        full = prompt + msgs[-1]["content"] + (tok.eos_token or "")
    p = tok(prompt, add_special_tokens=False)["input_ids"]
    f = tok(full, add_special_tokens=False)["input_ids"]
    if len(f) > max_len:
        return None
    return {"input_ids": f, "labels": [-100] * len(p) + f[len(p):], "attention_mask": [1] * len(f)}


def load(path, tok, max_len):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    enc = [encode(tok, r, max_len) for r in rows]
    kept = [e for e in enc if e]
    print("%s: %d examples, %d over %d tokens skipped" % (path, len(kept), len(rows) - len(kept), max_len), flush=True)
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=float, default=2)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--alpha", type=int, default=32)
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--accumulate", type=int, default=4)
    ap.add_argument("--max-len", type=int, default=2048)
    ap.add_argument("--save-steps", type=int, default=50)
    ap.add_argument("--eval-steps", type=int, default=50)
    ap.add_argument("--bits", type=int, default=4, choices=[4, 16])
    a = ap.parse_args()

    import torch
    from transformers import (AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, DataCollatorForSeq2Seq,
                              Trainer, TrainerCallback, TrainingArguments)
    from transformers.trainer_utils import get_last_checkpoint
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training

    signal.signal(signal.SIGTERM, _term)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    tok = AutoTokenizer.from_pretrained(a.model)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    train = load(Path(a.data) / "train.jsonl", tok, a.max_len)
    valid = load(Path(a.data) / "valid.jsonl", tok, a.max_len)
    # Longest first within the first batch surfaces an out-of-memory at once, not hours in.
    qcfg = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=torch.bfloat16,
                              bnb_4bit_use_double_quant=True) if a.bits == 4 else None
    model = AutoModelForCausalLM.from_pretrained(a.model, quantization_config=qcfg, dtype=torch.bfloat16, device_map={"": 0})
    if a.bits == 4:
        model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
    else:
        model.gradient_checkpointing_enable()
    model = get_peft_model(model, LoraConfig(r=a.rank, lora_alpha=a.alpha, lora_dropout=0.05, task_type="CAUSAL_LM",
                                             target_modules="all-linear"))
    model.print_trainable_parameters()

    class Supervisor(TrainerCallback):
        t0 = time.time()

        def on_step_end(self, args, state, control, **kw):
            if gpujob:
                gpujob.heartbeat(state.global_step)
                gpujob.throttle(time.time() - self.t0)
            if _stop or (gpujob and gpujob.stopping()):
                control.should_save = True
                control.should_training_stop = True
            self.t0 = time.time()

    targs = TrainingArguments(
        output_dir=str(out / "checkpoints"), num_train_epochs=a.epochs, learning_rate=a.lr, lr_scheduler_type="cosine",
        warmup_ratio=0.03, per_device_train_batch_size=a.batch, per_device_eval_batch_size=a.batch,
        gradient_accumulation_steps=a.accumulate, bf16=True, logging_steps=10, eval_strategy="steps",
        eval_steps=a.eval_steps, save_strategy="steps", save_steps=a.save_steps, save_total_limit=3,
        load_best_model_at_end=True, metric_for_best_model="eval_loss", greater_is_better=False,
        group_by_length=True, report_to=[], optim="paged_adamw_8bit", gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False}, dataloader_num_workers=2, seed=1)
    trainer = Trainer(model=model, args=targs, train_dataset=train, eval_dataset=valid,
                      data_collator=DataCollatorForSeq2Seq(tok, padding=True, label_pad_token_id=-100),
                      callbacks=[Supervisor()])
    last = get_last_checkpoint(str(out / "checkpoints")) if (out / "checkpoints").exists() else None
    print("resuming from %s" % last if last else "starting", flush=True)
    trainer.train(resume_from_checkpoint=last)
    if _stop or (gpujob and gpujob.stopping()):
        print("stopped; resumes from the newest checkpoint", flush=True)
        return 0
    trainer.save_model(str(out / "best"))  # the best checkpoint, loaded at the end
    tok.save_pretrained(str(out / "best"))
    hist = [h for h in trainer.state.log_history if "eval_loss" in h]
    (out / "history.json").write_text(json.dumps(trainer.state.log_history, indent=1))
    (out / "FINISHED").write_text(json.dumps({"best_eval_loss": min((h["eval_loss"] for h in hist), default=None),
                                              "best_checkpoint": trainer.state.best_model_checkpoint}))
    print("finished: best eval loss %s" % min((h["eval_loss"] for h in hist), default=None), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
