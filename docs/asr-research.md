# Local speech recognition for Murmur: research (2026-09-30)

Question: which on-device recognizer, on an M5 Pro under macOS 27, gets closest
to Wispr Flow on the author's own speech, inside a release-to-text budget of 500 ms p50.
This file is the desk research. The choice is made by `murmur bench` on the author's
recordings, not by the ranks below. Numbers are the sources' own; refs at the end.

## Comparison

WER is from the Open ASR Leaderboard [1] unless marked, shown as public 8-set
average / AMI (meetings) / Earnings22 / Monsoon en-IN (accented) / private
conversational (US, IN, GB, AU, CA accents). The leaderboard strips punctuation,
casing and fillers before scoring [3], so it says nothing about either.

| Model | Params, license | WER (avg / AMI / E22 / en-IN / conv) | Streaming | Punct, case | Biasing | Mac runtime |
| --- | --- | --- | --- | --- | --- | --- |
| Qwen3-ASR-1.7B | 2.0B, Apache-2.0 [12] | 4.31 / 8.31 / 5.84 / 3.50 / **12.14**, best open model on conversational [1] | Chunked re-decode of all audio every 2 s [13] | Yes (examples only) [12] | Context text in the prompt, unmeasured [12] | mlx-audio-swift (GPU) [18]; Argmax Pro SDK 3, paid [26] |
| Canary-Qwen-2.5B | 2.5B, CC-BY-4.0 [11] | 4.43 / 7.91 / 6.41 / 3.60 / 13.41 | Offline only | Yes; verbatim incl. repetitions [11] | None | No maintained Swift port found |
| Cohere Transcribe 03-2026 | 2B, Apache-2.0 [15] | 4.67 / 7.02 / 7.88 / 3.44 / 13.46; best open long-form, 12.23 [1] | Offline, 35 s per call [10] | Unverified (card gated) | Unverified | FluidAudio Core ML, int8 encoder 1.8 GB [10] |
| Granite-speech-4.1-2b | 2B, Apache-2.0 [16] | 4.62 / 7.06 / 6.69 / 4.12 / 14.19 | Offline | Yes, via prompt [16] | Keyword list in prompt [16] | mlx-audio (Python) [16] |
| Parakeet TDT 0.6B v2 | 0.6B, CC-BY-4.0 [5] | 4.70 / 9.09 / 6.76 / 3.89 / 13.58; MUSAN noise 6.95 at 10 dB, 11.88 at 0 dB [5] | Offline; naive chunking fails [9] | Yes [5] | External CTC keyword boosting [21] | FluidAudio Core ML on the ANE, ~120x real time on M4 Pro [20] |
| Parakeet TDT 0.6B v3 / Ultra | 0.6B, CC-BY-4.0 [6][24] | v3: 4.86 / 9.42 / 5.85 / 4.14 / 13.44. Ultra (self-reported): 7-set avg 5.80 vs v3 6.26, AMI 9.77 vs 10.86 [24] | Offline | Yes | External CTC boosting | FluidAudio; Ultra is its recommended default [10] |
| Parakeet Unified en 0.6B | 0.6B, NVIDIA Open Model License [9] | Self-reported avg 5.91 offline, 6.52 at 0.56 s latency [9]; LibriSpeech clean 2.15 batch, 2.21 streaming on M5 Pro [10] | One checkpoint, batch and chunked streaming [9] | Yes [10] | CTC boosting hook in FluidAudio [10] | FluidAudio, 123x real time batch on M5 Pro [10] |
| Nemotron speech streaming en 0.6B | 0.6B, NVIDIA Open Model License [7] | 5.25 / 8.84 / 9.45 / 4.44 / 13.28 (batch); streaming 6.93 avg at 1.12 s, AMI 18.29 at 80 ms [7] | Cache-aware, true streaming [7] | Yes [7] | None | FluidAudio, 560 ms tier 2.28% LibriSpeech at 42x on M5 Pro [20] |
| Voxtral Mini 4B Realtime | 4B, Apache-2.0 [19] | 6.46 / 13.34 / 9.31 / 8.86 / 17.45 | Native streaming, 480 ms recommended [19] | Undocumented | API only [19] | mlx-audio-swift [18] |
| Kyutai stt-2.6b-en | 2.6B, CC-BY-4.0 [22] | 5.57 / 10.52 / 8.89 / 6.13 / 14.90 | True streaming, fixed 2.5 s delay [22] | Yes | None | Swift port experimental, last push 2025-06 [23] |
| Moonshine streaming medium | 245M, MIT [25] | Not on leaderboard; self-reported 6.65 avg, 59 ms after speech ends [25] | True streaming | Undocumented | Keyterms list [25] | CPU only, Core ML dropped [25] |
| Whisper large-v3-turbo | 0.8B, MIT [27] | 6.36 / 13.88 / 8.09 / 4.77 / 15.40; tends to omit fillers [28] | Re-decoding wrappers only | Yes | Prompt text | WhisperKit, whisper.cpp |
| Apple SpeechTranscriber / DictationTranscriber | OS, proprietary [29] | 14.0 on earnings22 vs Parakeet v2 11.7 (M4, Argmax) [30]; 1.98% on a 40-speaker set, 125-132 ms median after speech ends (vendor) [31] | Volatile then final results [29] | Yes | `contextualStrings` (100 max) on DictationTranscriber only [29][32] | Built in; macOS 27 added input APIs, no new biasing [33] |

Qwen-Audio-3.0-ASR (2026-09-07) claims hotwords and streaming but has no open
weights yet [14]. OpenAI has released no open recognizer since Whisper turbo [27].

## What the dictation apps teach

- The clipped first word is a capture-startup bug in every open app: VoiceInk
  measured ~950 ms from trigger to capture because UI and audio start shared the
  main actor [34]; Handy ~500 ms [35]; Bluetooth mics worse [36]. Start capture
  first, draw the HUD after.
- Custom vocabulary on Parakeet over-corrects at FluidAudio's defaults: 278 of
  500 real dictations changed, "Maya" to "EMEA" 114 times; `cbw: 0,
  minSimilarity: 0.7` fixed most of it [37]. Boosting must be measured, not assumed.
- Clipboard restore races cause stale pastes [38]; Handy times the restore from
  pasteboard promise read receipts and guards on `changeCount` [39].
- Wispr's own budget: under 700 ms p99 after speech ends, ASR under 200 ms, LLM
  under 200 ms, network 200 ms, on cloud GPUs with a fine-tuned Llama [40].

## Shortlist

Push-to-talk hands the recognizer the whole clip at release, and Parakeet decodes
30 s in roughly 0.15-0.25 s on the ANE [20]. So an offline model with better
accuracy beats a true-streaming model that trades accuracy for early partials
(Nemotron's AMI goes from 8.84 batch to 18.29 at 80 ms chunks [7]). Murmur runs
each offline model on pause-bounded segments while the user speaks, so release only
decodes the tail since the last pause; the bench compares that with a whole-clip
decode on release.

1. **Parakeet TDT v2, FluidAudio, segmented, with and without tuned CTC boosting.**
   English-only, fast, mature Swift runtime. The baseline to beat.
2. **Parakeet Ultra, FluidAudio, segmented.** Same speed, claims better English.
3. **Parakeet Unified 0.6B, FluidAudio.** Chunked streaming partials plus a batch
   final from one checkpoint; tests whether streaming is worth its accuracy cost.
4. **Cohere Transcribe, FluidAudio.** Best open long-form WER; 2B, so latency and
   the 1.8 GB encoder decide it.
5. **Qwen3-ASR-1.7B through MLX.** Best open conversational WER and prompt-text
   biasing; GPU, which competes with the cleanup LLM for the same cores.

Reference, not a candidate unless it wins: Apple DictationTranscriber with
`contextualStrings` (no download, OS-maintained).

Two-recognizer architectures (a streaming model for partials, a stronger one on
release; or two recognizers reconciled by the cleanup model) are only worth
building if the bench shows the single best stack trails Wispr on the author's voice and
the second recognizer's time fits the budget.

## What the evidence cannot settle

- No independent M5 Pro or macOS 27 numbers exist for any runtime; FluidAudio's
  M5 Pro figures are self-reported on macOS 26 [10][20].
- Whispered and very quiet speech: no data for any model.
- Filler output and punctuation quality: unmeasured by the leaderboard [3]. Only
  Canary-Qwen (verbatim) and Whisper (drops fillers) are documented.
- Biasing gains on real dictation: Qwen3-ASR context and Cohere biasing are
  unmeasured; FluidAudio's boosting has a documented false-positive problem [37].
- Parakeet Ultra, Parakeet Unified and Moonshine are not on the leaderboard.
- The leaderboard's private "conversational" set is aggregated and not public [2].
- Wispr's recognizer is undisclosed; one competitor claims an OpenAI subprocessor [41].

## References

1. Open ASR Leaderboard, Space updated 2026-09-25, results CSV 2026-09-30. https://huggingface.co/spaces/hf-audio/open_asr_leaderboard, https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results
2. Leaderboard About text, 2026-09-25. https://huggingface.co/spaces/hf-audio/open_asr_leaderboard/blob/main/constants.py
3. Leaderboard normalizer and filler list, 2026-08-26. https://github.com/huggingface/open_asr_leaderboard/blob/main/normalizer/normalizer.py
4. (unused)
5. nvidia/parakeet-tdt-0.6b-v2, released 2025-05-01, edited 2026-06-29. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
6. nvidia/parakeet-tdt-0.6b-v3, 2025-08-14. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
7. nvidia/nemotron-speech-streaming-en-0.6b, 2026-03-13. https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
8. (unused)
9. nvidia/parakeet-unified-en-0.6b, 2026-04-07. https://huggingface.co/nvidia/parakeet-unified-en-0.6b
10. FluidAudio Models.md, 2026-09-25. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md
11. nvidia/canary-qwen-2.5b, 2025-07-17. https://huggingface.co/nvidia/canary-qwen-2.5b
12. Qwen/Qwen3-ASR-1.7B, 2026-01-28; tech report 2026-01-29. https://huggingface.co/Qwen/Qwen3-ASR-1.7B, https://arxiv.org/abs/2601.21337
13. Qwen3-ASR streaming inference, commit 2026-06-26. https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py
14. Qwen-Audio-3.0 report, 2026-09-07. https://arxiv.org/abs/2609.07549
15. Cohere Transcribe, 2026-03-24 (gated); coverage 2026-03-27. https://huggingface.co/CohereLabs/cohere-transcribe-03-2026, https://gigazine.net/gsc_news/en/20260327-cohere-transcribe
16. ibm-granite/granite-speech-4.1-2b, 2026-04-29. https://huggingface.co/ibm-granite/granite-speech-4.1-2b
17. (unused)
18. mlx-audio-swift README, 2026-09-13; v0.1.3 2026-07-09. https://github.com/Blaizzy/mlx-audio-swift
19. mistralai/Voxtral-Mini-4B-Realtime-2602, 2026-01-21; Voxtral Transcribe 2, 2026-02-04. https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602, https://mistral.ai/news/voxtral-transcribe-2
20. FluidAudio Benchmarks.md, 2026-09-20; README 2026-09-26. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
21. FluidAudio CustomVocabulary.md, 2026-09-09. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md
22. kyutai/stt-2.6b-en, 2025-06-06. https://huggingface.co/kyutai/stt-2.6b-en
23. kyutai-labs/moshi-swift, last push 2025-06-26. https://github.com/kyutai-labs/moshi-swift
24. moondream/parakeet-ultra and announcement, 2026-09-22. https://huggingface.co/moondream/parakeet-ultra, https://moondream.ai/blog/introducing-parakeet-redux-and-ultra
25. Moonshine v0.1.5 and docs, 2026-08-10 to 2026-08-24. https://github.com/moonshine-ai/moonshine, https://github.com/moonshine-ai/moonshine/blob/main/docs/moonshine-vs-whisper.md, https://github.com/moonshine-ai/moonshine/blob/main/docs/execution-providers.md
26. Argmax SDK 3, 2026-09-23; custom vocabulary, 2025-11-19. https://www.argmaxinc.com/blog/argmax-sdk-3, https://www.argmaxinc.com/blog/customize-speech-to-text
27. openai/whisper-large-v3-turbo, 2024-10-01. https://huggingface.co/openai/whisper-large-v3-turbo
28. CrisperWhisper, 2024-08. https://arxiv.org/abs/2408.16589
29. Apple DictationTranscriber and SpeechTranscriber docs (macOS 26.0+), read 2026-09-30. https://developer.apple.com/documentation/speech/dictationtranscriber
30. Argmax, "Apple and Argmax", 2025-06-20. https://www.argmaxinc.com/blog/apple-and-argmax
31. IraVoice 40-speaker Mac benchmark, 2026-08-01 (vendor). https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4
32. AnalysisContext.contextualStrings (macOS 26.0+); forum thread on SpeechTranscriber ignoring it. https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings, https://developer.apple.com/forums/thread/801877
33. Apple Speech updates, June 2026. https://developer.apple.com/documentation/updates/speech
34. VoiceInk issue 572, 2026-03-07. https://github.com/Beingpax/VoiceInk/issues/572
35. Handy issue 1283, 2026-04-12. https://github.com/cjpais/Handy/issues/1283
36. VoiceInk issue 659, 2026-04-21; OpenWhispr issue 845, 2026-05-23. https://github.com/Beingpax/VoiceInk/issues/659, https://github.com/OpenWhispr/openwhispr/issues/845
37. FluidAudio issue 967, 2026-09-26. https://github.com/FluidInference/FluidAudio/issues/967
38. Handy issues 1764 (2026-07-22), 502 (2025-12-30). https://github.com/cjpais/Handy/issues/1764
39. Handy paste_tx/macos.rs, read 2026-09-30. https://github.com/cjpais/Handy/blob/main/src-tauri/src/paste_tx/macos.rs
40. Wispr, "Technical challenges behind Flow", 2025-09-11. https://wisprflow.ai/post/technical-challenges
41. Spokenly, Wispr Flow review, updated 2026-05. https://spokenly.app/blog/wispr-flow-review
