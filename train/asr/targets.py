#!/usr/bin/env python3
"""Fine-tuning targets for Parakeet: the ceiling transcript's words in Parakeet's own style.

The ceiling (`murmur ceiling transcripts`) is the best transcript available without a person, but its
punctuation, casing and fillers follow whichever voter or judge wrote it. Training Parakeet on it
directly would also retrain its style. So each target is the stock Parakeet transcript with only its
word errors corrected: aligned word by word to the ceiling, a word both share keeps Parakeet's form
(punctuation, casing), a misheard, missing or extra word takes the ceiling's, and fillers Parakeet
heard stay.

  targets.py --items items.jsonl --base asr-parakeet-unified-nemo.jsonl --ceiling ceiling-transcripts.jsonl \
             --out manifests/ [--dev-fraction 0.08] [--dev-from corpus]

Writes manifests/train.jsonl and dev.jsonl (NeMo: audio_filepath, duration, text) and stats.json.
"""
import argparse, hashlib, json, re
from pathlib import Path

FILLERS = {"um", "uh", "er", "ah", "hmm", "mm", "mhm", "erm", "uhm"}


def key(tok):
    k = re.sub(r"[^\w']", "", tok.lower().replace("’", "'")).strip("'")
    return k


def is_filler(tok):
    return key(tok) in FILLERS


def proper(r, j):
    """The reference capitalizes this word where a sentence does not start."""
    return r[j][:1].isupper() and j > 0 and r[j - 1][-1:] not in ".?!:" and key(r[j]) != "i"


def minimal_edit(base, ref):
    """Parakeet's tokens where they agree with the reference, the reference's where they do not."""
    b, r = base.split(), ref.split()
    bk, rk = [key(t) for t in b], [key(t) for t in r]
    n, m = len(b), len(r)
    INF = float("inf")
    cost = [[INF] * (m + 1) for _ in range(n + 1)]
    back = [[None] * (m + 1) for _ in range(n + 1)]
    cost[0][0] = 0
    for i in range(n + 1):
        for j in range(m + 1):
            c = cost[i][j]
            if c == INF:
                continue
            if i < n and j < m:
                step = 0 if bk[i] == rk[j] else 1
                if c + step < cost[i + 1][j + 1]:
                    cost[i + 1][j + 1], back[i + 1][j + 1] = c + step, ("keep" if step == 0 else "sub")
            if i < n:  # a base word the reference lacks: dropped, unless a filler (kept, free) or punctuation-only
                step = 0 if (is_filler(b[i]) or not bk[i]) else 1
                if c + step < cost[i + 1][j]:
                    cost[i + 1][j], back[i + 1][j] = c + step, ("filler" if step == 0 else "del")
            if j < m:
                step = 0 if not rk[j] else 1
                if c + step < cost[i][j + 1]:
                    cost[i][j + 1], back[i][j + 1] = c + step, "ins"
    out, i, j, edits = [], n, m, 0
    while i > 0 or j > 0:
        op = back[i][j]
        if op in ("keep", "filler"):
            tok = b[i - 1]
            if op == "keep" and proper(r, j - 1) and tok[:1].islower():
                tok = tok[:1].upper() + tok[1:]  # a name the reference capitalizes mid-sentence
            out.append(tok)
            i, j = (i - 1, j - 1) if op == "keep" else (i - 1, j)
        elif op == "sub":
            out.append(r[j - 1]); i, j = i - 1, j - 1; edits += 1
        elif op == "del":
            i -= 1; edits += 1
        else:  # ins
            if rk[j - 1]:
                out.append(r[j - 1]); edits += 1
            j -= 1
    out.reverse()
    # A sentence that now starts on a corrected word starts with a capital.
    for k, t in enumerate(out):
        if (k == 0 or out[k - 1][-1:] in ".?!") and t[:1].islower():
            out[k] = t[:1].upper() + t[1:]
    return " ".join(out), edits


def load_rows(path, field="text"):
    out = {}
    for line in open(path):
        if line.strip():
            d = json.loads(line)
            out[d["id"]] = d[field]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", required=True, help="{id, audio, seconds, source} per line")
    ap.add_argument("--base", required=True)
    ap.add_argument("--ceiling", action="append", required=True, help="ceiling-transcripts.jsonl (repeatable)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--dev-fraction", type=float, default=0.08)
    ap.add_argument("--dev-from", default="corpus", help="source whose items may go to dev")
    ap.add_argument("--max-seconds", type=float, default=25)
    ap.add_argument("--max-edit-rate", type=float, default=0.5, help="skip clips where Parakeet and the ceiling disagree this much")
    a = ap.parse_args()
    items = [json.loads(l) for l in open(a.items) if l.strip()]
    base = load_rows(a.base)
    ceiling = {}
    for c in a.ceiling:
        ceiling.update(load_rows(c))
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    items_dir = Path(a.items).parent.resolve()
    stats = {"items": len(items), "no_label": 0, "too_long": 0, "too_different": 0, "train": 0, "dev": 0, "edited_clips": 0, "edits": 0, "words": 0}
    with open(out / "train.jsonl", "w") as tr, open(out / "dev.jsonl", "w") as dv:
        for i in items:
            if i["seconds"] > a.max_seconds:
                stats["too_long"] += 1
                continue
            if i["id"] not in base or i["id"] not in ceiling or not ceiling[i["id"]].strip():
                stats["no_label"] += 1
                continue
            text, edits = minimal_edit(base[i["id"]], ceiling[i["id"]])
            words = max(len(text.split()), 1)
            if edits / words > a.max_edit_rate or not text.strip():
                stats["too_different"] += 1
                continue
            row = {"audio_filepath": str((items_dir / i["audio"]).resolve()), "duration": i["seconds"], "text": text, "id": i["id"]}
            is_dev = i.get("source") == a.dev_from and int(hashlib.sha1(i["id"].encode()).hexdigest(), 16) % 1000 < a.dev_fraction * 1000
            (dv if is_dev else tr).write(json.dumps(row) + "\n")
            stats["dev" if is_dev else "train"] += 1
            stats["edited_clips"] += edits > 0
            stats["edits"] += edits
            stats["words"] += words
    (out / "stats.json").write_text(json.dumps(stats, indent=1))
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
