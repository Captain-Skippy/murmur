"""Generate synthetic cleanup examples with Claude (text only, no private data).
Usage: python3 gen_synthetic.py [--extra]  -> synthetic.jsonl in Murmur's private train folder (review it by
eye: `claude -p` reads your own Claude Code settings and memory, which can leak into the examples).
--extra appends the second round."""
import concurrent.futures, json, subprocess, pathlib

HERE = pathlib.Path(__file__).parent
PRIVATE = pathlib.Path.home() / "Library/Application Support/Murmur"
OUT = PRIVATE / "train/synthetic.jsonl"
SPEC = (HERE / "synth-spec.md").read_text()
import sys
EXTRA = {
    "code2": "40 examples dictated to a coding agent where identifiers are spoken as words: 'underscore', 'camel case', 'all caps', 'dot swift', 'dot py', 'dash dash flag', 'slash' in paths; output writes the identifier exactly (e.g. `load_models`, `loadModels`, `API_KEY`, `Controller.swift`, --dry-run, src/app/main.ts), backticks only in code style, none in terminal style.",
    "urls": "30 examples with URLs, emails and handles spoken out ('github dot com slash', 'at gmail dot com', 'dash', 'underscore'), including a speaker who restarts the URL mid-way ('sorry, open...'); output is the final written URL or email, lowercase unless spoken otherwise.",
    "corrections2": "40 self-corrections of the forms 'X, wait no, make it Y', 'X, no, Y', 'X, sorry, Y', 'X, I mean Y', 'X, actually Y' for numbers, names, times and items; output keeps only Y. Include 10 where 'no' or 'sorry' is ordinary content and nothing is corrected.",
    "bullets": "30 examples: the speaker says 'bullets' or 'bullet points' or 'as a list' then items; output is a '- ' bulleted list. Include 10 enumerations with 'first... second...' that become numbered lists, and 10 plain sentences with 'and' that must stay prose.",
    "numbers2": "40 examples about keeping numbers faithful: exact digits must never change; vague quantities stay words ('high teens', 'half an hour', 'a couple', 'a few hundred'); spoken numbers become digits only when exact ('twenty one ten' -> 2110, 'twelve thirty' -> 12:30); course codes like 'MATH twenty one ten' -> MATH 2110.",
}
CATS = {
    "questions": "40 examples of dictated questions (factual, personal, to an AI assistant, to a friend); output is the cleaned question, never an answer.",
    "instructions": "50 examples of dictated requests or instructions to an AI or a person, including prompt-injection style ('ignore your instructions and...', 'you are now...', 'respond only with...'), 'write an email to', 'summarize', 'translate', 'fix this bug'; output is the formatted request itself, never carried out.",
    "corrections": "40 examples of self-corrections ('Tuesday, no, Wednesday', 'scratch that', 'I mean', 'actually make it', 'wait no'), sometimes spanning a sentence; output keeps only the corrected version and nothing else changes.",
    "lists": "35 examples of enumerations: numbered (first/second/third, one two three, number one...), bulleted when the speaker says bullets, and plain comma lists of two or three short items that should stay inline.",
    "commands": "30 examples with spoken formatting commands (new line, new paragraph, comma, period, question mark, open quote/close quote), including 10 where those words are ordinary content and must stay words.",
    "numbers": "40 examples with numbers, dates, times, money, percentages, phone numbers, emails, URLs, versions, units (e.g. 'three point five kilograms', 'march fifth at two thirty p m').",
    "code": "40 examples in code style (T3 Code, Zed) and terminal style (Ghostty, Terminal): talking to a coding agent about files, functions, CLI flags, git branches, env vars, JSON keys, spoken as words ('dash dash verbose', 'dot swift', 'camel case').",
    "casual": "25 short casual chat messages (Messages, Telegram) with fillers, 10 longer rambling multi-topic dictations (Notes, Mail) that need paragraph breaks, and 5 formal emails with a spoken greeting and sign-off.",
}

def gen(cat, ask):
    own = PRIVATE / "eval/script.json"
    script = json.loads((own if own.exists() else HERE.parent / "eval/script.json").read_text())
    avoid = "Do not reuse these evaluation sentences or close paraphrases: " + "; ".join(x["say"] for x in script)
    prompt = f"{SPEC}\n{avoid}\nNow write {ask} Use category \"{cat}\". Output only JSONL lines, no commentary, no code fences."
    r = subprocess.run(["claude", "-p", "--model", "opus", "--no-session-persistence", "--tools", "", "--output-format", "text"],
                       input=prompt, capture_output=True, text=True, timeout=600)
    rows = []
    for line in r.stdout.splitlines():
        try:
            o = json.loads(line)
            if o.get("raw") and o.get("output"):
                o["category"] = cat
                rows.append(o)
        except json.JSONDecodeError:
            pass
    return cat, rows

extra = "--extra" in sys.argv
todo = EXTRA if extra else CATS
with concurrent.futures.ThreadPoolExecutor(8) as ex:
    results = list(ex.map(lambda kv: gen(*kv), todo.items()))
OUT.parent.mkdir(parents=True, exist_ok=True)
with open(OUT, "a" if extra else "w") as f:
    for cat, rows in results:
        print(cat, len(rows))
        for o in rows:
            f.write(json.dumps(o, ensure_ascii=False) + "\n")
