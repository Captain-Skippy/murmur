"""Chunk-shaped training targets, so the cleanup model learns to clean a piece of a long
dictation as well as a whole one (`ChunkedCleanup`). Each long training transcript is split the
way the chunker splits it (a chunk closes at the first sentence end past 40 to 80 words, or at
120); Claude writes each chunk's cleaned text, consistent with the transcript's training target
but using only that chunk's words. Text only (no audio) goes to Anthropic through the Claude
Code CLI; eval items are never included (the export already excludes them). Output stays
private: ~/Library/Application Support/Murmur/train/chunks.jsonl, keyed like relabel.jsonl.
Run after an export (train.sh, or `murmur export-training`). Usage: python3 train/chunks.py [--limit N]"""
import concurrent.futures, hashlib, json, pathlib, random, re, subprocess, sys

T = pathlib.Path.home() / "Library/Application Support/Murmur/train"
OUT = T / "chunks.jsonl"
RULES = (pathlib.Path(__file__).parent / "synth-spec.md").read_text().split("The formatter rules")[1]
MIN_WORDS, MAX_WORDS = 60, 120

SYSTEM = """You write training targets for a dictation formatter that cleans a long dictation in
pieces while the speaker is still talking. Each piece is formatted on its own: the formatter sees
only that piece's transcript, never the pieces before or after. For each case you get the app, the
whole raw transcript, the whole formatted reference (good; follow its choices), and the raw pieces
in order. For every piece, write exactly what the formatter should output for that piece alone:
- Use only that piece's words. Never carry a word from a neighboring piece in or out.
- Follow the reference's wording, punctuation, numbers and formatting wherever the piece alone
  supports them. A self-correction or a list that spans pieces is formatted as far as the piece
  itself shows it; a piece that continues a list keeps the list's form.
- A piece is not a new document: no greeting, heading or sign-off unless spoken in it.
The formatter rules""" + RULES + """
Reply with only a JSON array, one object per case in order: {"id": "...", "pieces": ["...", ...]}
with exactly as many pieces as the case has."""


def key(raw):
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def split(raw, rng):
    """Sentence-ending chunks as `ChunkedCleanup` closes them; the rest is the release tail."""
    sentences = re.findall(r"\S.*?(?:[.?!](?=\s|$)|$)", raw, re.S)
    lo = rng.choice((40, 60, 80))
    pieces, cur = [], []
    for s in sentences:
        cur.append(s.strip())
        n = len(" ".join(cur).split())
        if n >= MAX_WORDS or (n >= lo and cur[-1][-1:] in ".?!"):
            pieces.append(" ".join(cur)); cur = []
    if cur:
        pieces.append(" ".join(cur))
    return [p for p in pieces if p]


def cases():
    seen, rng = set(), random.Random(7)
    for f in ("train.jsonl", "valid.jsonl"):
        for line in (T / "data" / f).read_text().splitlines():
            m = json.loads(line)["messages"]
            user, target = m[1]["content"], m[2]["content"]
            raw = re.search(r"<transcript>(.*)</transcript>", user, re.S).group(1)
            k = key(raw)
            if k in seen or len(raw.split()) < MIN_WORDS:
                continue
            seen.add(k)
            pieces = split(raw, rng)
            if len(pieces) < 2:
                continue
            app = (re.search(r"<app>(.*?)</app>", user) or [None, "unknown"])[1]
            yield {"id": k, "app": app, "raw": raw, "reference": target, "pieces": pieces}


def run(batch):
    prompt = json.dumps([{k: c[k] for k in ("id", "app", "raw", "reference", "pieces")} for c in batch],
                        ensure_ascii=False, indent=1)
    r = subprocess.run(["claude", "-p", "--model", "opus", "--no-session-persistence", "--tools", "",
                        "--output-format", "text", "--system-prompt", SYSTEM],
                       input=prompt, capture_output=True, text=True, timeout=1200)
    s = r.stdout
    try:
        arr = json.loads(s[s.index("["): s.rindex("]") + 1])
    except ValueError:
        return []
    by = {c["id"]: c for c in batch}
    out = []
    for o in arr:
        c = by.get(o.get("id"))
        p = o.get("pieces")
        if c and isinstance(p, list) and len(p) == len(c["pieces"]) and all(isinstance(x, str) and x.strip() for x in p):
            out.append({"id": c["id"], "chunks": [{"raw": r, "output": x.strip()} for r, x in zip(c["pieces"], p)]})
    return out


def main():
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    done = {json.loads(l)["id"] for l in OUT.read_text().splitlines()} if OUT.exists() else set()
    todo = [c for c in cases() if c["id"] not in done][:limit]
    batches = [todo[i:i + 6] for i in range(0, len(todo), 6)]
    print(f"{len(todo)} to split in {len(batches)} batches", flush=True)
    with OUT.open("a") as f, concurrent.futures.ThreadPoolExecutor(6) as ex:
        for n, res in enumerate(ex.map(run, batches), 1):
            for o in res:
                f.write(json.dumps(o, ensure_ascii=False) + "\n")
            f.flush()
            if n % 10 == 0:
                print(f"{n}/{len(batches)} batches", flush=True)
    OUT.chmod(0o600)


if __name__ == "__main__":
    main()
