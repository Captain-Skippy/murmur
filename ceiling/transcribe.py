#!/usr/bin/env python3
"""Transcribe an eval set with one transcribe.cpp model (Metal) and save the text as a bench
recognizer result (results/asr-NAME.jsonl), so `murmur ceiling` can use it as a voter.

  ceiling/transcribe.py --set wispr --name whisper-large-v3 --gguf PATH [--max-seconds 60]

The binary and models live outside the repo, in ~/Library/Caches/murmur-ceiling
(ceiling/setup.sh). Only items without a saved result are transcribed."""
import argparse, json, os, subprocess, sys, tempfile, time
from pathlib import Path

CACHE = Path.home() / "Library/Caches/murmur-ceiling"
EVAL = Path.home() / "Library/Application Support/Murmur/eval"
CLI = CACHE / "transcribe.cpp/build/bin/transcribe-cli"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="wispr")
    ap.add_argument("--name", required=True)
    ap.add_argument("--gguf", required=True)
    ap.add_argument("--max-seconds", type=float, default=60)
    a = ap.parse_args()

    d = EVAL / a.set
    items = [json.loads(l) for l in open(d / "manifest.jsonl") if l.strip()]
    items = [i for i in items if i["seconds"] <= a.max_seconds and not i.get("excluded")]
    out = d / "results" / f"asr-{a.name}.jsonl"
    done = set()
    if out.exists():
        done = {json.loads(l)["id"] for l in open(out) if l.strip()}
    todo = [i for i in items if i["id"] not in done]
    if not todo:
        print(f"{a.name}: all {len(items)} items already transcribed")
        return
    by_path = {str((d / i["audio"]).resolve()): i["id"] for i in todo}
    with tempfile.NamedTemporaryFile("w", suffix=".list", dir=d, delete=False) as f:
        f.write("\n".join(by_path) + "\n")
        listfile = f.name
    t0 = time.time()
    try:
        p = subprocess.run([str(CLI), "-q", "-m", a.gguf, "-l", "en", "--batch", listfile, "--batch-jsonl"],
                           capture_output=True, text=True)
    finally:
        os.unlink(listfile)
    rows = []
    for line in p.stdout.splitlines():
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        path = o.get("file") or o.get("path") or o.get("audio")
        iid = by_path.get(str(Path(path).resolve())) if path else None
        if iid is None or o.get("error"):
            continue
        rows.append({"id": iid, "stack": a.name, "text": (o.get("text") or "").strip(), "tailMs": 0,
                     "segments": 1, "maxSegmentRTF": 0})
    with open(out, "a") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    os.chmod(out, 0o600)
    audio = sum(i["seconds"] for i in todo)
    print(f"{a.name}: {len(rows)}/{len(todo)} items, {audio/60:.1f} min of audio in {time.time()-t0:.0f} s")
    if len(rows) < len(todo):
        print(p.stderr[-2000:], file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
