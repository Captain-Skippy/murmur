#!/usr/bin/env python3
"""Transcribe a set of clips with strong recognizers on a CUDA GPU, saved the way `murmur bench-asr`
saves a recognizer's results (results/asr-NAME.jsonl), so `murmur ceiling transcripts` can vote with
them and `train/asr/targets.py` can build fine-tuning targets.

  voters.py --manifest items.jsonl --out results/ [--models whisper-large-v3,canary-qwen-2.5b,...]

items.jsonl: one {"id", "audio" (path, relative to the manifest), "seconds"} per line; 16 kHz mono wav.
Resumable: an item already in a model's results file is skipped, and each batch is appended as it
finishes, so a stopped run continues where it left off.
"""
import argparse, json, os, sys, time
from pathlib import Path

try:  # optional supervisor hooks (heartbeat, pause, duty cycle); no-ops elsewhere
    import gpujob
except ImportError:
    gpujob = None

MODELS = ["parakeet-unified-nemo", "whisper-large-v3", "canary-qwen-2.5b", "granite-speech-4.1-2b"]


def load_items(manifest, max_seconds):
    base = Path(manifest).parent
    items = []
    for line in open(manifest):
        if line.strip():
            i = json.loads(line)
            if i["seconds"] <= max_seconds:
                i["path"] = str((base / i["audio"]).resolve())
                items.append(i)
    return items


def done_ids(path):
    if not path.exists():
        return set()
    out = set()
    for line in open(path):
        try:
            out.add(json.loads(line)["id"])
        except (ValueError, KeyError):
            pass  # a line cut off by a stop: redone
    return out


def append(path, rows):
    with open(path, "a") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())


def row(item, stack, text, ms):
    return {"id": item["id"], "stack": stack, "text": text.strip(), "tailMs": ms, "wholeMs": None, "wholeText": None,
            "segments": 1, "maxSegmentRTF": ms / 1000 / max(item["seconds"], 0.01)}


def load_audio(path):
    import soundfile as sf
    wav, sr = sf.read(path, dtype="float32")
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    assert sr == 16000, "%s: %d Hz" % (path, sr)
    return wav


class Whisper:
    """Whisper large-v3, one 30 s window per clip (clips here are 30 s or shorter), batched generate."""
    def __init__(self):
        import torch
        from transformers import WhisperForConditionalGeneration, WhisperProcessor
        name = "openai/whisper-large-v3"
        self.proc = WhisperProcessor.from_pretrained(name)
        self.m = WhisperForConditionalGeneration.from_pretrained(name, dtype=torch.float16).cuda().eval()

    def __call__(self, items):
        import torch
        x = self.proc([load_audio(i["path"]) for i in items], sampling_rate=16000, return_tensors="pt")
        with torch.inference_mode():
            y = self.m.generate(x.input_features.cuda().half(), language="english", task="transcribe", max_new_tokens=440)
        return self.proc.batch_decode(y, skip_special_tokens=True)


class Canary:
    def __init__(self):
        from nemo.collections.speechlm2.models import SALM
        self.m = SALM.from_pretrained("nvidia/canary-qwen-2.5b").bfloat16().eval().cuda()

    def __call__(self, items):
        import torch
        prompts = [[{"role": "user", "content": "Transcribe the following: %s" % self.m.audio_locator_tag, "audio": [i["path"]]}] for i in items]
        with torch.inference_mode():
            ids = self.m.generate(prompts=prompts, max_new_tokens=int(max(i["seconds"] for i in items) * 8 + 32))
        return [self.m.tokenizer.ids_to_text(x.cpu()) for x in ids]


class Granite:
    def __init__(self):
        import torch
        from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor
        name = "ibm-granite/granite-speech-4.1-2b"
        self.proc = AutoProcessor.from_pretrained(name)
        self.tok = self.proc.tokenizer
        self.m = AutoModelForSpeechSeq2Seq.from_pretrained(name, device_map="cuda", dtype=torch.bfloat16).eval()
        chat = [{"role": "user", "content": "<|audio|>transcribe the speech with proper punctuation and capitalization."}]
        self.prompt = self.tok.apply_chat_template(chat, tokenize=False, add_generation_prompt=True)

    def __call__(self, items):
        import torch
        out = []
        for i in items:  # one at a time: the processor pads audio features, not worth batching here
            wav = torch.from_numpy(load_audio(i["path"])).unsqueeze(0)
            x = self.proc(self.prompt, wav, device="cuda", return_tensors="pt").to("cuda")
            with torch.inference_mode():
                y = self.m.generate(**x, max_new_tokens=int(i["seconds"] * 8 + 32), do_sample=False, num_beams=1)
            out.append(self.tok.batch_decode(y[:, x["input_ids"].shape[-1]:], add_special_tokens=False, skip_special_tokens=True)[0])
        return out


class Parakeet:
    """The stock Parakeet Unified checkpoint (or a fine-tuned one, --checkpoint) in NeMo, offline mode, greedy."""
    def __init__(self, checkpoint=None):
        import nemo.collections.asr as nemo_asr
        import torch
        DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import finetune
        self.decode = finetune.decode
        if checkpoint:
            self.m = nemo_asr.models.ASRModel.restore_from(checkpoint, map_location=DEVICE)
        else:
            self.m = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-unified-en-0.6b", map_location=DEVICE)
        finetune.offline_only(self.m)
        self.m.eval()

    def __call__(self, items):
        return self.decode(self.m, [{"audio_filepath": i["path"], "duration": i["seconds"], "text": ""} for i in items])


def make(name, checkpoint=None):
    return {"whisper-large-v3": Whisper, "canary-qwen-2.5b": Canary, "granite-speech-4.1-2b": Granite}.get(name, lambda: Parakeet(checkpoint))()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--models", default=",".join(MODELS))
    ap.add_argument("--checkpoint", help="a .nemo to decode as --models NAME (a fine-tuned Parakeet)")
    ap.add_argument("--max-seconds", type=float, default=30)
    ap.add_argument("--batch", type=int, default=16)
    a = ap.parse_args()
    import torch
    items = load_items(a.manifest, a.max_seconds)
    items.sort(key=lambda i: i["seconds"])  # similar lengths batch together
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    total = 0
    for name in a.models.split(","):
        path = out / ("asr-%s.jsonl" % name)
        todo = [i for i in items if i["id"] not in done_ids(path)]
        print("%s: %d of %d to do" % (name, len(todo), len(items)), flush=True)
        if not todo:
            continue
        model = make(name, a.checkpoint)
        for k in range(0, len(todo), a.batch):
            batch = todo[k:k + a.batch]
            t0 = time.time()
            texts = model(batch)
            ms = (time.time() - t0) * 1000 / len(batch)
            append(path, [row(i, name, t, ms) for i, t in zip(batch, texts)])
            total += len(batch)
            if gpujob:
                gpujob.heartbeat("%s %d/%d" % (name, k + len(batch), len(todo)))
                gpujob.throttle(time.time() - t0)
                if gpujob.stopping():
                    print("stopping at %s %d" % (name, k + len(batch)), flush=True)
                    return 0
        del model
        torch.cuda.empty_cache()
    print("done: %d transcripts" % total, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
