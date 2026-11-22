#!/usr/bin/env python3
"""Cleanups from a tuned teacher (sft.py's adapter on its base model), greedy, for distilling a
smaller student: each input's system and user turns go in, the teacher's reply comes out as the
assistant turn, in the same chat format sft.py and train/train.sh train on.

  generate.py --model Qwen/Qwen3.5-9B --adapter RUN/best --inputs inputs.jsonl --out teacher.jsonl

inputs.jsonl: {"id", "messages": [system, user, (assistant ignored)]} per line. Resumable: ids
already in --out are skipped; each batch is appended as it finishes.
"""
import argparse, json, os, sys, time
from pathlib import Path

try:
    import gpujob
except ImportError:
    gpujob = None

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sft import render  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter")
    ap.add_argument("--inputs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--bits", type=int, default=4, choices=[4, 16])
    a = ap.parse_args()
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
    tok = AutoTokenizer.from_pretrained(a.adapter or a.model)
    tok.padding_side = "left"
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    qcfg = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=torch.bfloat16,
                              bnb_4bit_use_double_quant=True) if a.bits == 4 else None
    model = AutoModelForCausalLM.from_pretrained(a.model, quantization_config=qcfg, torch_dtype=torch.bfloat16, device_map={"": 0})
    if a.adapter:
        from peft import PeftModel
        model = PeftModel.from_pretrained(model, a.adapter)
    model.eval()
    out = Path(a.out)
    done = set()
    if out.exists():
        for l in open(out):
            try:
                done.add(json.loads(l)["id"])
            except (ValueError, KeyError):
                pass
    rows = [json.loads(l) for l in open(a.inputs) if l.strip()]
    todo = [r for r in rows if r["id"] not in done]
    todo.sort(key=lambda r: len(r["messages"][1]["content"]))
    print("%d inputs, %d to generate" % (len(rows), len(todo)), flush=True)
    for k in range(0, len(todo), a.batch):
        t0 = time.time()
        batch = todo[k:k + a.batch]
        prompts = [render(tok, r["messages"][:2], True) for r in batch]
        x = tok(prompts, return_tensors="pt", padding=True, add_special_tokens=False).to(0)
        longest = max(len(r["messages"][1]["content"]) for r in batch)
        with torch.inference_mode():
            y = model.generate(**x, max_new_tokens=min(1536, longest // 2 + 64), do_sample=False, pad_token_id=tok.pad_token_id)
        texts = tok.batch_decode(y[:, x["input_ids"].shape[1]:], skip_special_tokens=True)
        with open(out, "a") as f:
            for r, t in zip(batch, texts):
                t = t.split("</think>")[-1].strip()
                f.write(json.dumps({"id": r["id"], "messages": r["messages"][:2] + [{"role": "assistant", "content": t}]}) + "\n")
            f.flush()
            os.fsync(f.fileno())
        if gpujob:
            gpujob.heartbeat(k + len(batch))
            gpujob.throttle(time.time() - t0)
            if gpujob.stopping():
                return 0
    print("done", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
