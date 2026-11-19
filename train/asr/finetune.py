#!/usr/bin/env python3
"""Fine-tune Parakeet Unified 0.6B (NeMo) on one speaker's dictations, offline (full-context) mode,
on one CUDA GPU with 12 GB or more. Built to be stopped at any moment: it checkpoints every few
minutes and on SIGTERM, and a rerun with the same arguments continues from the last checkpoint at the
same batch of the same epoch.

  finetune.py --train train.jsonl --dev dev.jsonl --work run/ [--epochs 8] [--lr 3e-5]

Manifests are NeMo's: {"audio_filepath", "duration", "text"} per line (16 kHz mono wav). Writes
run/last.pt (resume state), run/best.nemo (lowest dev WER so far), run/history.jsonl (one line per
epoch: train loss, dev WER). Dev WER is a quick normalized word error rate for choosing the epoch.
"""
import argparse, json, math, os, random, re, signal, sys, threading, time
from pathlib import Path

try:  # optional supervisor hooks (heartbeat, pause, duty cycle); no-ops elsewhere
    import gpujob
except ImportError:
    gpujob = None

BASE = "nvidia/parakeet-unified-en-0.6b"
FILLERS = {"um", "uh", "er", "ah", "hmm", "mm", "mhm", "erm", "uhm"}
_stop = threading.Event()


def stopping():
    return _stop.is_set() or (gpujob is not None and gpujob.stopping())


def normalize(s):
    s = s.lower().replace("’", "'")
    words = []
    for w in re.split(r"[\s/—–-]+", s):
        w = re.sub(r"^[^\w]+|[^\w']+$", "", w).strip("'")
        if not w or w in FILLERS:
            continue
        words.append("<num>" if re.fullmatch(r"[\d.,:]+", w) else w)
    return words


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]


def wer(refs, hyps):
    errs = words = 0
    for r, h in zip(refs, hyps):
        r, h = normalize(r), normalize(h)
        errs += edit_distance(r, h)
        words += len(r)
    return errs / max(words, 1)


def read_manifest(path, max_seconds):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    base = Path(path).parent
    for r in rows:
        r["audio_filepath"] = str((base / r["audio_filepath"]).resolve())
    return [r for r in rows if r["duration"] <= max_seconds and r["text"].strip()]


def epoch_batches(rows, epoch, seed, max_batch_seconds):
    """The same batches for the same epoch every time, so a resumed run continues exactly."""
    rng = random.Random(seed * 1000 + epoch)
    idx = list(range(len(rows)))
    rng.shuffle(idx)
    batches = []
    for g in range(0, len(idx), 64):  # sort within groups of 64 so a batch pads little
        group = sorted(idx[g:g + 64], key=lambda i: rows[i]["duration"])
        cur, longest = [], 0.0
        for i in group:
            d = rows[i]["duration"]
            if cur and max(longest, d) * (len(cur) + 1) > max_batch_seconds:
                batches.append(cur)
                cur, longest = [], 0.0
            cur.append(i)
            longest = max(longest, d)
        if cur:
            batches.append(cur)
    rng.shuffle(batches)
    return batches


def load_batch(rows, ids, tokenizer, device):
    import numpy as np, soundfile as sf, torch
    wavs, toks = [], []
    for i in ids:
        w, sr = sf.read(rows[i]["audio_filepath"], dtype="float32")
        if w.ndim > 1:
            w = w.mean(axis=1)
        assert sr == 16000
        wavs.append(w)
        toks.append(tokenizer.text_to_ids(rows[i]["text"]) if tokenizer else [0])
    n = max(len(w) for w in wavs)
    audio = torch.zeros(len(wavs), n)
    for k, w in enumerate(wavs):
        audio[k, :len(w)] = torch.from_numpy(w)
    alen = torch.tensor([len(w) for w in wavs])
    m = max(len(t) for t in toks)
    tgt = torch.zeros(len(toks), m, dtype=torch.long)
    for k, t in enumerate(toks):
        tgt[k, :len(t)] = torch.tensor(t)
    tlen = torch.tensor([len(t) for t in toks])
    return audio.to(device), alen.to(device), tgt.to(device), tlen.to(device)


def offline_only(model):
    """Train the full-context (offline) mode only: the mode Murmur decodes with."""
    enc = model.encoder
    full = None
    for c in getattr(enc, "att_context_size_all", None) or []:
        if all(int(x) < 0 for x in c):
            full = c
    if full is not None:
        enc.att_context_size_all = [full]
        if hasattr(enc, "att_context_probs"):
            enc.att_context_probs = [1.0]
        enc.set_default_att_context_size(full)
    return full


def frozen_params(model, freeze_layers):
    """Freeze the feature front end and the lowest encoder layers; returns the trainable parameters."""
    for p in model.preprocessor.parameters():
        p.requires_grad = False
    if freeze_layers > 0:
        for p in model.encoder.pre_encode.parameters():
            p.requires_grad = False
        for layer in model.encoder.layers[:freeze_layers]:
            for p in layer.parameters():
                p.requires_grad = False
    return [p for p in model.parameters() if p.requires_grad]


def greedy(model, audio, alen):
    """Batch greedy decode, the way the offline Core ML path decodes."""
    enc, elen = model.forward(input_signal=audio, input_signal_length=alen)
    hyps = model.decoding.rnnt_decoder_predictions_tensor(encoder_output=enc, encoded_lengths=elen)
    if isinstance(hyps, tuple):
        hyps = hyps[0]
    return [h.text if hasattr(h, "text") else str(h) for h in hyps]


def decode(model, rows, batch_seconds=200.0):
    import torch
    device = next(model.parameters()).device
    order = sorted(range(len(rows)), key=lambda i: rows[i]["duration"])
    out = [None] * len(rows)
    model.eval()
    with torch.inference_mode(), (torch.autocast(device_type="cuda", dtype=torch.bfloat16) if device.type == "cuda" else torch.autocast(device_type="cpu", enabled=False)):
        k = 0
        while k < len(order):
            ids = [order[k]]
            while k + len(ids) < len(order) and (len(ids) + 1) * rows[order[k + len(ids)]]["duration"] <= batch_seconds:
                ids.append(order[k + len(ids)])
            n = len(ids)
            audio, alen, _, _ = load_batch(rows, ids, None, device)
            for i, t in zip(ids, greedy(model, audio, alen)):
                out[i] = t
            k += n
    model.train()
    return out


def save_state(path, model, opt, sched, scaler, epoch, pos, step, extra):
    import torch
    state = {"model": model.state_dict(), "opt": opt.state_dict(), "sched": sched.state_dict(),
             "epoch": epoch, "pos": pos, "step": step, "extra": extra}
    tmp = Path(str(path) + ".partial")
    torch.save(state, tmp)
    with open(tmp, "rb") as f:
        os.fsync(f.fileno())
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", required=True)
    ap.add_argument("--dev", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--base", default=BASE, help="pretrained name or a .nemo path")
    ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--warmup", type=int, default=100)
    ap.add_argument("--max-seconds", type=float, default=25.0)
    ap.add_argument("--batch-seconds", type=float, default=120.0, help="audio seconds per forward pass (padded)")
    ap.add_argument("--accumulate", type=int, default=2)
    ap.add_argument("--freeze-layers", type=int, default=0)
    ap.add_argument("--optimizer", default="adamw8bit", choices=["adamw8bit", "adamw"])
    ap.add_argument("--weight-decay", type=float, default=1e-3)
    ap.add_argument("--checkpoint-minutes", type=float, default=8.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-steps", type=int, default=0, help="stop after this many optimizer steps (smoke tests)")
    a = ap.parse_args()

    import torch
    import nemo.collections.asr as nemo_asr
    from omegaconf import open_dict

    signal.signal(signal.SIGTERM, lambda *_: _stop.set())
    work = Path(a.work)
    work.mkdir(parents=True, exist_ok=True)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    torch.manual_seed(a.seed)
    train, dev = read_manifest(a.train, a.max_seconds), read_manifest(a.dev, a.max_seconds)
    print("train %d clips %.2f h, dev %d clips" % (len(train), sum(r["duration"] for r in train) / 3600, len(dev)), flush=True)

    if a.base.endswith(".nemo"):
        model = nemo_asr.models.ASRModel.restore_from(a.base, map_location="cpu")
    else:
        model = nemo_asr.models.ASRModel.from_pretrained(a.base, map_location="cpu")
    full = offline_only(model)
    print("attention context for training:", full, flush=True)
    model = model.to(device)
    model.train()
    params = frozen_params(model, a.freeze_layers)
    print("trainable parameters: %.0fM of %.0fM" % (sum(p.numel() for p in params) / 1e6, sum(p.numel() for p in model.parameters()) / 1e6), flush=True)
    if a.optimizer == "adamw8bit" and device == "cuda":
        import bitsandbytes as bnb
        opt = bnb.optim.AdamW8bit(params, lr=a.lr, weight_decay=a.weight_decay)
    else:
        opt = torch.optim.AdamW(params, lr=a.lr, weight_decay=a.weight_decay)
    steps_per_epoch = math.ceil(len(epoch_batches(train, 0, a.seed, a.batch_seconds)) / a.accumulate)
    total = steps_per_epoch * a.epochs
    lr_at = lambda s: min(1.0, (s + 1) / a.warmup) * max(0.05, 0.5 * (1 + math.cos(math.pi * min(1.0, s / max(total, 1)))))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_at)

    epoch, pos, step, extra = 0, 0, 0, {"best_wer": None, "best_epoch": None}
    last = work / "last.pt"
    if last.exists():
        st = torch.load(last, map_location=device, weights_only=False)
        model.load_state_dict(st["model"])
        opt.load_state_dict(st["opt"])
        sched.load_state_dict(st["sched"])
        epoch, pos, step, extra = st["epoch"], st["pos"], st["step"], st["extra"]
        print("resumed at epoch %d batch %d step %d" % (epoch, pos, step), flush=True)
        del st
    elif extra["best_wer"] is None:
        base_wer = wer([r["text"] for r in dev], decode(model, dev))
        extra.update(base_wer=base_wer, best_wer=base_wer, best_epoch=-1)
        print("dev WER before fine-tuning: %.2f%%" % (100 * base_wer), flush=True)
        with open(work / "history.jsonl", "a") as f:
            f.write(json.dumps({"epoch": -1, "dev_wer": base_wer}) + "\n")

    def checkpoint(why):
        t0 = time.time()
        save_state(last, model, opt, sched, None, epoch, pos, step, extra)
        print("checkpoint (%s) at epoch %d batch %d step %d in %.1f s" % (why, epoch, pos, step, time.time() - t0), flush=True)

    last_ck = time.time()
    amp = torch.autocast(device_type="cuda", dtype=torch.bfloat16) if device == "cuda" else torch.autocast(device_type="cpu", enabled=False)
    while epoch < a.epochs:
        batches = epoch_batches(train, epoch, a.seed, a.batch_seconds)
        losses = []
        while pos < len(batches):
            t0 = time.time()
            audio, alen, tgt, tlen = load_batch(train, batches[pos], model.tokenizer, device)
            with amp:
                enc, elen = model.forward(input_signal=audio, input_signal_length=alen)
                dec, dlen, _ = model.decoder(targets=tgt, target_length=tlen)
                if model.joint.fuse_loss_wer:
                    loss = model.joint(encoder_outputs=enc, decoder_outputs=dec, encoder_lengths=elen,
                                       transcripts=tgt, transcript_lengths=dlen, compute_wer=False)[0]
                else:
                    joint = model.joint(encoder_outputs=enc, decoder_outputs=dec)
                    loss = model.loss(log_probs=joint, targets=tgt, input_lengths=elen, target_lengths=dlen)
            (loss / a.accumulate).backward()
            losses.append(loss.item())
            pos += 1
            if pos % a.accumulate == 0 or pos == len(batches):
                torch.nn.utils.clip_grad_norm_(params, 1.0)
                opt.step()
                sched.step()
                opt.zero_grad(set_to_none=True)
                step += 1
                if step % 10 == 0:
                    print("epoch %d step %d batch %d/%d loss %.3f lr %.2e %.0f MB" % (
                        epoch, step, pos, len(batches), sum(losses[-20:]) / len(losses[-20:]), sched.get_last_lr()[0],
                        torch.cuda.max_memory_allocated() / 2**20 if device == "cuda" else 0), flush=True)
            if gpujob:
                gpujob.heartbeat(step, epoch=epoch)
                gpujob.throttle(time.time() - t0)
            if stopping():
                if pos % a.accumulate == 0:
                    checkpoint("stop")
                else:  # mid-accumulation: the partial gradient is lost, so resume at the last full step
                    pos -= pos % a.accumulate
                    opt.zero_grad(set_to_none=True)
                    checkpoint("stop")
                return 0
            if time.time() - last_ck > 60 * a.checkpoint_minutes and pos % a.accumulate == 0:
                checkpoint("timer")
                last_ck = time.time()
            if a.max_steps and step >= a.max_steps:
                checkpoint("max steps")
                return 0
        dev_wer = wer([r["text"] for r in dev], decode(model, dev))
        rec = {"epoch": epoch, "step": step, "train_loss": sum(losses) / max(len(losses), 1), "dev_wer": dev_wer}
        print("epoch %d done: %s" % (epoch, json.dumps(rec)), flush=True)
        with open(work / "history.jsonl", "a") as f:
            f.write(json.dumps(rec) + "\n")
        if extra["best_wer"] is None or dev_wer < extra["best_wer"]:
            extra.update(best_wer=dev_wer, best_epoch=epoch)
            tmp = work / "best.nemo.partial"
            model.save_to(str(tmp))
            os.replace(tmp, work / "best.nemo")
            print("new best: epoch %d dev WER %.2f%%" % (epoch, 100 * dev_wer), flush=True)
        epoch, pos = epoch + 1, 0
        checkpoint("epoch")
        last_ck = time.time()
    (work / "FINISHED").write_text(json.dumps(extra))
    print("finished: best epoch %s dev WER %.2f%% (before %.2f%%)" % (
        extra["best_epoch"], 100 * extra["best_wer"], 100 * (extra.get("base_wer") or float("nan"))), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
