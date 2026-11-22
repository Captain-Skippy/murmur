# Training a larger cleanup model on a CUDA GPU

The Mac trains the shipped cleanup model (`train/train.sh`, MLX LoRA on Qwen3-4B). These scripts do the
same on one NVIDIA GPU (12 GB is enough) for a model too slow to ship, then distill it back into the
4B the app runs:

1. `murmur export-training` on the Mac writes the chat-format data (`train.jsonl`, `valid.jsonl`).
2. `sft.py --model Qwen/Qwen3.5-9B --bits 4` tunes the teacher (QLoRA).
3. `murmur export-prompts` on the Mac writes the app's exact prompts for held-out sets and for unlabeled
   transcripts; `generate.py` cleans them with the teacher.
4. `sft.py --model Qwen/Qwen3-4B-Instruct-2507 --bits 16` tunes the student on the original data plus the
   teacher's cleanups; `merge.py` folds its adapter into a full model.
5. On a Mac: `mlx_lm convert --hf-path MERGED -q --q-bits 4 --mlx-path ~/Library/Application Support/Murmur/models/tuned-NAME`,
   then `murmur bench-cleanup --cleaners tuned-NAME+lookup` and `murmur ceiling score`.
   `murmur import-cleanups` grades the teacher's raw outputs the same way.

Every script resumes after a stop (checkpoints, appended outputs), so a run survives a laptop closing.
Nothing of a user's data belongs in this repository: the data, prompts and models stay private.
