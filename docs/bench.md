# Bench results (2026-09-30, ceiling 2026-10-03)

Measured on an M5 Pro MacBook Pro, macOS 27.0.1, with `murmur bench-asr`, `bench-cleanup`,
`judge` and `consensus`. Eval data stays on the Mac; these are the numbers only.
Sets: `scripted` (40 lines read aloud by the author, hand-checked references), `wispr` (622 clips
from Wispr Flow's local history; 158 held out as `test`, cleanup and judge are
scored only there; recognition uses all). The judge is Claude Sonnet through the
Claude Code CLI, blind and order-randomized; swapping every pair changed the
overall score by 0.5 points and 76% of single verdicts held.

## Recognition (chosen: Parakeet Unified 0.6B, FluidAudio, Neural Engine, corrected by a vote; see "More time for quality")

| Stack | Scripted WER | whisper | noisy | Wispr history, consensus WER | Tail after release p50 / p95 | Dictionary terms (false) |
| --- | --- | --- | --- | --- | --- | --- |
| parakeet-unified | 5.4% | 5.3% | 10.3% | 2.81% (Wispr 2.81%) | 46 / 109 ms | 123/133 (6) |
| parakeet-ultra | 6.2% | 5.3% | 10.3% | 2.64%* | 45 / 107 ms | 118/133 (4) |
| parakeet-v2 | 5.9% | 10.5% | 6.9% | 3.58% | 44 / 79 ms | 115/133 (6) |
| apple-speech | 9.4% | 10.7% | 20.7% | 4.49% | 112 / 285 ms | 104/133 |
| apple-dictation | 14.0% | 14.3% | 20.7% | 9.10% | 413 / 831 ms | 113/133 |
| cohere-transcribe | - | - | - | 4.88% | 430 / 572 ms | 125/133 (5) |
| qwen3-asr-1.7b | 4.0% | 5.3% | 0.0% | 8.1% vs Wispr; quiet 64.6% | 248 / 750 ms | 127/133 (666) |

Consensus WER: each system against the word-level vote of Wispr, Parakeet
Unified, Apple SpeechTranscriber and Cohere, excluding itself. *Ultra shares its
family with a voter and is flattered. CTC vocabulary boosting (FluidAudio) added
~130 ms and 40+ false dictionary insertions; off. Qwen3-ASR hallucinates on quiet
audio and its context biasing floods terms; rejected despite the best scripted WER.
Pause segmentation costs 0.0 to 0.2 points of WER against whole-clip decoding.

## Cleanup (chosen: Qwen3-4B-Instruct-2507, 4-bit, LoRA fine-tuned here, v5; v7 since Oct 10, see "Chunked cleanup")

Formatting only (Wispr's recognizer text as input, 134 held-out items):

| Cleaner | Better or tied vs Wispr | Judge flags added / dropped (Wispr) | Cleanup p50 / p95 |
| --- | --- | --- | --- |
| qwen3-4b prompted | 60% (30 items) | | 362 / 897 ms |
| tuned 1.7B v1 | 74% (392 items) | 5 / 7 (12 / 12) | 84 / 250 ms |
| tuned 4B v3 | 85.1% | 3 / 5 (6 / 1) | 192 / 596 ms |
| tuned 4B v5 | 85.1% | 0 / 4 (7 / 7) | 204 / 570 ms |

End to end (Parakeet Unified + cleanup vs Wispr end to end, same audio, spoken
reference is the recognizer consensus): v3 64.2%, v5 61.2% and 60.4% on a second
run, better or tied (bar 90%). Answered or obeyed content: zero for every tuned model; the prompted 4B
obeyed "reply only with the word banana", which the hard checks now reject.
Prompt-lookup speculation accepts 3.4 to 6.2 tokens per model call and roughly
halves cleanup time.

## Against the ceiling (2026-10-03)

The ceiling is the best transcript and cleanup reachable today without a person and
without a latency budget (`murmur ceiling`, sources in `Sources/murmur/Ceiling.swift`).
Six recognizer families vote word by word: Wispr's cloud transcript, Cohere, Qwen3-ASR
1.7B, Whisper large-v3, Canary-Qwen 2.5B and Granite Speech 4.1 2B (the last three via
transcribe.cpp, `ceiling/`). Parakeet never votes, because Murmur ships it. Claude Opus 5.5
(medium effort) settles disputed spans using only the voters' readings, then writes the
ideal cleanup. Claude also grades each candidate against it: an item is "at reference
quality" when the grader finds no real error. Only text reaches Claude.

Validation on `scripted` (hand-written references): the ceiling transcript scores 3.0%
WER, below every single recognizer (best: Qwen3-ASR 4.0%, Parakeet Unified 4.7%), and most
of what remains are lines read differently from the script (all six voters agree). The
ceiling cleanup is at hand-written quality on 39 of 40 lines.

| Set | Recognition WER vs ceiling | At reference quality | Same cleanup, ceiling transcript |
| --- | --- | --- | --- |
| `murmur` (83 of the author's live dictations, Murmur's own output) | live 2.2% | 49.4% | 83.1% |
| `wispr` held-out (139 items) | Parakeet Unified 2.8%, Wispr 1.6%* | Murmur 45.3%, Wispr 54.0% | 68.3% |

*Wispr votes on the ceiling, so its number is flattered. Errors on `wispr` per 139 items,
Murmur vs Wispr: misheard 38 / 28, dropped 17 / 9, disfluency left 29 / 12, punctuation
18 / 11. With a perfect transcript, Murmur's cleanup still leaves 36 disfluency errors and
drops content in 8 items; on `murmur`, most dropped content was heard correctly and lost in
cleanup. The grader moved 5 points between two runs on the same 40 outputs, so differences
under about 5 points are noise. Claude declined one batch of 8 history items; their transcripts
fall back to the vote and they have no ideal cleanup.

## More time for quality (2026-10-03)

Release to text may now take p50 1000 ms and p95 2000 ms (up to 30 s clips). Each option was
graded against the ceiling with `ceiling score --candidates asr:cleaner`; a grade is reused
for any item whose output text is unchanged, so options differ only on items they change
("fixed" and "broke" count items against today's Murmur). Regrading identical outputs agreed
on 99% of verdicts (197 of 199). Fair WER: against the vote of recognizers that are neither
Murmur's nor its voters (Wispr where present, Whisper large-v3, Canary-Qwen, Granite), so a
vote cannot flatter itself; on `scripted`, the hand references.

| Option | `murmur` (83) | `wispr` held-out (139) | `scripted` (40) | Fixed / broke, all sets | Fair WER murmur / wispr / scripted hand |
| --- | --- | --- | --- | --- | --- |
| Today: Parakeet Unified segmented + v5 | 54.2% | 45.3% | 65.0% | | 2.53% / 3.14% / 4.71% |
| Whole-clip re-decode at release | 2 of 78 transcripts differ (up to 30 s), WER vs ceiling 2.00% to 1.95% | | | not graded | |
| Vote: Parakeet Unified, Cohere, Qwen3-ASR 1.7B + v5 | 60.2% | 50.4% | 72.5% | 16 / 1 | 2.16% / 2.81% / 3.53% |
| **Vote: Parakeet Unified, Qwen3-ASR 1.7B, Parakeet v2 + v5 (shipped)** | 56.6% | 48.2% | 75.0% | 14 / 4 | 2.25% / 2.76% / 4.37% |
| Vote: Parakeet Unified, Cohere, Apple Speech + v5 (earlier rule, free deletions) | 53.0% | 47.5% | | 11 / 9 | 2.61% / 2.64% / - |
| Cleanup v6 (v5 recipe, targets rewritten by the ceiling prompt) on Parakeet | 51.8% | 43.2% | 75.0% | 14 / 15 | |
| Cleanup v6 on the ceiling transcript (v5: 83.1% / 68.3% / 77.5%) | 83.1% | 58.3% | 82.5% | | |

The vote (`TranscriptVote`, `VotingRecognizer`, stack `parakeet-unified+vote`): every
recognizer decodes each pause segment at once; Parakeet's text stands unless both voters agree
on another word or an inserted word; a word only Parakeet heard is dropped only beside a
replaced word (a product name heard as two words, joined by the voters), since alone the voters more often clipped it. Voters
run without the dictionary (no biasing), Qwen3-ASR capped at 12 tokens per second of audio, and
a voter still decoding 1.2 s after Parakeet sits that segment out. Typical fixes: a misheard
name, "Eng" to "English", a dropped "again" or "I think". Per set the gains are under the
5-point noise of unpaired grading; paired, 14 items fixed against 4 broken, and fair WER falls
on all three references. The Cohere vote scores a little higher but Cohere's Core ML encoder
maps about 24 GB (file-backed) and its tail puts release to text near the p50 bar; it stays
available as `parakeet-unified+vote-cohere`. v6 learned to add and drop words from the
relabeled targets (on `murmur` and `wispr`: added 4 and 10, dropped 10 and 20) and was not
shipped; v5 stays.
A drop detector (a run of three or more spoken content words missing) caught 2 to 4 of 8 to 17
graded drops per set, too few for a repair pass.

Headless key release to text with `murmur e2e` (real-time audio into the live session, tail,
cleanup; no paste), 40 `murmur` clips up to 30 s, v5 cleanup:

| Recognizer | Release to text p50 / p95 / max | Recognition tail p50 / p95 | Cleanup p50 / p95 | Resident memory (process, with v5) |
| --- | --- | --- | --- | --- |
| parakeet-unified | 317 / 616 / 931 ms | 77 / 178 ms | 215 / 533 ms | +2.3 GB |
| parakeet-unified+vote (shipped) | 588 / 1422 / 1831 ms | 321 / 931 ms | 254 / 549 ms | +4.8 GB |
| parakeet-unified+vote-cohere | 894 / 1336 / 1410 ms | 678 / 958 ms | 218 / 527 ms | +28.8 GB |

Live (`timings.jsonl`, 138 dictations up to 30 s, before the vote): p50 434 ms, p95 891 ms,
so the live path adds roughly 100 to 300 ms to the headless numbers.

## Latency

Headless key release to text (recognition tail + cleanup, per clip), v5: p50
260 ms, p95 789 ms on the 134 held-out clips up to 30 s (bar 500 / 1000). Wispr's
own logged e2e on the same clips: p50 511 ms, p95 998 ms. Live numbers (capture start, paste receipt) are
in `~/Library/Logs/Murmur/timings.jsonl`.

## What would close the formatting gap

A larger cleanup model (8B-class) should gain a few points at roughly double the
decode time, likely over the p95 bar. More of the user's own pairs through shadow
captures and relabeling have given the steadiest gains so far (+11 points
from v1 to v3). Fine-tuning Parakeet on the user's recordings could narrow the
end-to-end gap caused by recognizer differences; it needs NeMo training outside
the app and about 10 hours of labeled audio for a reliable gain.

## Chunked cleanup (2026-10-10: shipped with cleanup v7, chunks of 40 words)

Long dictations past 60 s fell back to the raw transcript 34% of the time and made the live p95.
`ChunkedCleanup` cleans sentence-ending chunks while the speaker talks (`cleanupChunkWords`,
default 40). Set `long`: 24 `murmur` dictations of 30 to 150 s, ceiling built from five
voters (Wispr absent), graded by Claude Opus 5.5; transcripts identical across rows.

| Cleanup | Release to text p50 / p95 (e2e) | Hard-check fallbacks | Grader errors (paired: fewer / more vs whole) |
| --- | --- | --- | --- |
| v5 whole, one call (shipped until Oct 10) | 1272 / 3004 ms | 3 | 71 |
| Chunks of 40 words, earlier chunks as text before | 821 / 2175 ms | 8 (model copied earlier chunks) | not graded |
| Chunks of 40 words | 803 / 2152 ms | 5 | 84 (4 / 9) |
| Chunks of 80 words | 1027 / 2156 ms | not counted | 81 (3 / 6) |
| v7 whole, one call | 1321 / 3160 ms | 0 | 68 (8 / 7) |
| **v7, chunks of 40 words (shipped)** | 749 / 1610 ms | 5 | 78 (8 / 11) |

Chunking is faster but drops more words and leaves more disfluencies: v5 was trained on whole
utterances and cleans a mid-dictation fragment worse. v7 is the v5 recipe plus 724 chunk-shaped
cases (`train/chunks.py`: 285 long training transcripts split as the chunker splits them, each
piece's target written by Claude Opus 5.5 from the whole target; 1000 iterations, best at 600).
It halves the chunking penalty (+7 errors against v5 whole, paired 8 fewer / 11 more, within
grading noise) and puts long dictations inside the latency bar; speed won. On short
dictations v7 ties v5 (ceiling errors on `murmur` / `wispr` / `scripted` 54 / 122 / 12 against
52 / 117 / 11; at reference 54.2% / 47.5% / 72.5% against 56.6% / 48.2% / 75.0%).

## Whispers (2026-10-09)

Scripted `whisper-1` to `-4` (speech about -32 to -36 dBFS) mixed into real room noise from the
corpus (-52 dBFS, the built-in mic's floor) at 0 to 20 dB lower: every recognizer is word-perfect
to about -12 dB, then degrades together; at -16 to -20 dB Parakeet Unified returns nothing on 2
of 8, and Qwen3-ASR is the least bad (it still hallucinates on silence). Pure attenuation without
noise changes nothing down to -25 dB, so the limit is signal to noise, not level. ffmpeg `afftdn`
and RNNoise (`arnndn`) before Parakeet made every case worse. Live, 15 dictations of 1 to 11 s
returned nothing; from this build their audio is kept in the corpus. Next: the whispered lines
`whisper-5` to `-20`, then a Parakeet fine-tune here with quiet and noisy augmentation.
