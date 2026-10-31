"""Better training targets: Claude cleans each training transcript, with Wispr's output shown
as a reference to keep or improve. Text only (no audio) goes to Anthropic through the Claude
Code CLI; eval items are never included (the export already excludes them). Output stays
private: ~/Library/Application Support/Murmur/train/relabel.jsonl, keyed by the raw text.
Usage: python3 train/relabel.py [--limit N]"""
import concurrent.futures, hashlib, json, pathlib, re, subprocess, sys

T = pathlib.Path.home() / "Library/Application Support/Murmur/train"
OUT = T / "relabel.jsonl"
RULES = (pathlib.Path(__file__).parent / "synth-spec.md").read_text().split("The formatter rules")[1]

SYSTEM = """You produce the ideal output of a dictation formatter. For each case you get the app, the
raw speech-recognizer transcript, and a reference output from another formatter. Write the text the
speaker meant to type. The reference is usually good: keep its choices unless it breaks a rule, keeps
fillers or false starts, misses a self-correction, changes meaning, or invents structure.
The formatter rules""" + RULES + """
Reply with only a JSON array, one object per case in order: {"id": "...", "output": "..."}"""


def key(raw):
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def cases():
    seen = set()
    for f in ("train.jsonl", "valid.jsonl"):
        for line in (T / "data" / f).read_text().splitlines():
            m = json.loads(line)["messages"]
            user, target = m[1]["content"], m[2]["content"]
            raw = re.search(r"<transcript>(.*)</transcript>", user, re.S).group(1)
            app = (re.search(r"<app>(.*?)</app>", user) or [None, "unknown"])[1]
            k = key(raw)
            if k not in seen:
                seen.add(k)
                yield {"id": k, "app": app, "raw": raw, "reference": target}


def run(batch):
    prompt = json.dumps(batch, ensure_ascii=False, indent=1)
    r = subprocess.run(["claude", "-p", "--model", "opus", "--no-session-persistence", "--tools", "",
                        "--output-format", "text", "--system-prompt", SYSTEM],
                       input=prompt, capture_output=True, text=True, timeout=900)
    s = r.stdout
    try:
        arr = json.loads(s[s.index("["): s.rindex("]") + 1])
    except ValueError:
        return []
    ids = {c["id"] for c in batch}
    return [o for o in arr if o.get("id") in ids and isinstance(o.get("output"), str)]


def main():
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    done = {json.loads(l)["id"] for l in OUT.read_text().splitlines()} if OUT.exists() else set()
    todo = [c for c in cases() if c["id"] not in done][:limit]
    batches = [todo[i:i + 12] for i in range(0, len(todo), 12)]
    print(f"{len(todo)} to relabel in {len(batches)} batches", flush=True)
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
