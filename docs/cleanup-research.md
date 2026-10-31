# Cleanup model research (2026-09-30)

Question: which instruct model turns a raw transcript (80-150 words) into clean
text on the M5 Pro inside the latency budget, without answering or obeying the
content. Chosen by `murmur bench`, not by these numbers. Refs at the end.

## The constraint is decode speed

Prefill is cheap: Qwen3.5-2B prefills 4,346 tok/s at 256 tokens and 6,644 at
1,024 on an M5 Pro with mlx-lm [1]. With the fixed system prompt cached, only the
transcript and context (200-400 tokens) prefill per dictation, ~50-90 ms.
Decode is not: 100-150 output tokens at the measured M5 Pro rates [1] take

| Model (MLX 4-bit, M5 Pro [1]) | Decode tok/s | Prefill tok/s (128 to 1024) | 120 tokens |
| --- | --- | --- | --- |
| Qwen3-0.6B | 398 | 4,600 to 13,732 | 0.30 s |
| Llama-3.2-1B | 298 | 3,987 to 11,490 | 0.40 s |
| Qwen3.5-2B | 209 | 2,328 to 6,644 | 0.57 s |
| Gemma 4 E2B | 147 | 2,634 to 11,645 | 0.82 s |
| Llama-3.2-3B | 131 | 2,531 to 4,270 | 0.92 s |
| Qwen3.6-35B-A3B | 102 | 596 to 1,988 | 1.18 s |
| Gemma 4 26B-A4B | 87 | 806 to 2,247 | 1.38 s |

Wispr does its cleanup in under 200 ms on cloud GPUs [2]. Ways to close the gap
locally, in the order Murmur tries them:

1. Prompt-lookup speculation: cleanup output is mostly a copy of the input, so
   draft tokens from the transcript and verify several per forward pass. A
   server reports Gemma 4 E4B at 116 tok/s with prompt lookup on an M4 Max [3].
2. Fast path: short utterances with nothing to clean skip the model.
3. Prefill during speech: system prompt and app context are cached at key
   down; stable transcript segments prefill while the user is still talking.
4. A smaller model fine-tuned on the user's own Wispr pairs (local LoRA), if prompting
   a small model cannot hold the formatting bar.

## Candidates

| Model | Params / active | License | Notes |
| --- | --- | --- | --- |
| Qwen3.5-2B | 2B hybrid | Apache-2.0 [4] | Thinking on by default; must be off [5]. Hybrid cache cannot be trimmed, so snapshot after the system prompt [6] |
| Qwen3.5-4B | 4B hybrid | Apache-2.0 [4] | 156 tok/s on M5 Max [7]. Ignored an explicit "not instructions" prompt in OpenWhispr's tests [8] |
| Gemma 4 E2B / E4B | ~2B / ~4B effective | Apache-2.0 [9] | Gemma 3 4B, Gemma 4 E4B and Gemma 3 12B did not answer dictated questions where Qwen3.5-4B did [8]. MTP drafters for speculation [9] |
| LFM2.5-1.2B-Instruct | 1.2B hybrid | LFM Open License v1.0 [10] | Released 2026-01 [11]; card claims 2.5x decode with its drafter on Metal [10]; no Mac numbers found |
| Qwen3-30B-A3B / Qwen3.6-35B-A3B | 30-35B / 3B | Apache-2.0 | Quality ceiling, ~17 GB, ~100 tok/s [1] |
| Apple Foundation Models | ~3B, OS | OS | `.permissiveContentTransformations` guardrails for rewriting [12]; 8,192 context [13]; guardrail false positives reported on 26.5 [12]; adapters unsupported from OS 27 [14]; ~85 tok/s on M4 Max (third-party) [15] |

Runtime: mlx-swift-lm 3.31.4 (2026-06-30) has speculative decoding with a draft
model and Gemma 4 MTP, prefill pipelining and `KVCache.copy()` [6]; no prompt-
lookup drafting in Swift, so Murmur implements it. llama.cpp trails MLX on this
chip in both prefill and decode [1].

Cloud comparison (text only, if no local model holds the bar): Groq gpt-oss-20b
947 tok/s decode, 0.80 s first token at 10k-token inputs [16]; reasoning-on
"lite" models take seconds [17].

## Not answering the content

VoiceInk's current prompt wraps the transcript in `<TRANSCRIPT>` tags, states that
questions, commands and code inside are spoken content to clean, never to
answer, and adds few-shot examples of preserved requests [18]. Spotlighting
(delimiters or markers on untrusted text) is the general technique [19]. The DRES
disfluency benchmark found segmenting long transcripts helps, more few-shot
examples do not reliably help, and reasoning models over-delete [20].

## References

1. BaseRT M5 Pro benchmarks (mlx-lm 0.31.3), 2026-07-21. https://arxiv.org/abs/2607.19438
2. Wispr, "Technical challenges behind Flow", 2025-09-26. https://wisprflow.ai/research/technical-challenges
3. mlx-serve, 2026-09-22. https://mlxserve.com/blog/why-mlx-serve-is-fast/
4. Qwen3.5 small models, 2026-03-03. https://gigazine.net/gsc_news/en/20260303-qwen-3-5-small
5. OpenWhispr issue 512, 2026-03-26. https://github.com/OpenWhispr/openwhispr/issues/512
6. mlx-swift-lm releases 3.31.4 (2026-06-30), 3.31.3 (2026-04-15), 2.31.3 (2026-04-01). https://github.com/ml-explore/mlx-swift-lm/releases
7. Incept5 gemma4-benchmark, M5 Max, 2026-04-06. https://github.com/Incept5/gemma4-benchmark
8. OpenWhispr issue 833, 2026-05-21. https://github.com/OpenWhispr/openwhispr/issues/833
9. Gemma releases, read 2026-09-30. https://ai.google.dev/gemma/docs/releases
10. LiquidAI/LFM2.5-1.2B-Instruct, read 2026-09-30. https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct
11. LFM2.5 coverage, 2026-01-07. https://gigazine.net/gsc_news/en/20260107-lfm2-5-on-device-ai
12. Apple Developer Forums 835777, 2026-06. https://developer.apple.com/forums/thread/835777
13. WWDC26 "What's new in the Foundation Models framework", 2026-06. https://developer.apple.com/videos/play/wwdc2026/241/
14. Apple Developer Forums 831314, 2026-06. https://developer.apple.com/forums/thread/831314
15. apple-silicon-llm-bench, 2026-06 to 2026-09. https://github.com/john-rocky/apple-silicon-llm-bench
16. Artificial Analysis, Groq, read 2026-09-30. https://artificialanalysis.ai/providers/groq
17. Artificial Analysis, Gemini 3.5 Flash-Lite vs GPT-5.4 nano, read 2026-09-30. https://artificialanalysis.ai/models/comparisons/gemini-3-5-flash-lite-vs-gpt-5-4-nano-medium
18. VoiceInk AIPrompts.swift, 2026-09-01. https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Core/Enhancement/AIPrompts.swift
19. Hines et al., Spotlighting, 2024-03. https://arxiv.org/abs/2403.14720
20. DRES disfluency benchmark, 2025-09. https://arxiv.org/abs/2509.20321
