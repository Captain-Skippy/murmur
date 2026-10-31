#!/bin/zsh
# Fine-tune a cleanup model on this Mac from your Wispr Flow history (eval items held out) plus
# synthetic examples (train/gen_synthetic.py writes them to the private train folder), then fuse it into ~/Library/Application Support/Murmur/models/tuned-NAME.
# Data, adapters and weights stay private on this Mac. Usage: train/train.sh CONFIG.yaml NAME
# RELABEL names the target files under train/, first match wins (default: relabel.jsonl).
# CHUNKS names a chunk-target file under train/ (train/chunks.py) to add chunk-shaped cases.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=$1; NAME=$2
T="$HOME/Library/Application Support/Murmur/train"
M="$HOME/Library/Application Support/Murmur/models"
mkdir -p "$T/runs" "$M"; chmod 700 "$T" "$M"
[[ -x "$T/.venv/bin/python" ]] || { uv venv -q --python 3.12 "$T/.venv"; uv pip install -q --python "$T/.venv/bin/python" mlx-lm; }
EXTRA=(); [[ -n "${CHUNKS:-}" ]] && EXTRA=(--chunks "$CHUNKS")
.build/release/murmur export-training --synthetic "$T/synthetic.jsonl" --synthetic-weight 2 --relabel-file "${RELABEL:-relabel.jsonl}" "${EXTRA[@]}"
sed "s|^adapter_path:.*|adapter_path: runs/$NAME-adapter|" "$CONFIG" > "$T/runs/$NAME.yaml"
(cd "$T" && .venv/bin/python -m mlx_lm lora -c "runs/$NAME.yaml" 2>&1 | tee "runs/$NAME.log")
# Fuse the checkpoint with the lowest validation loss, from the local snapshot (offline).
BASE=$(grep '^model:' "$CONFIG" | awk '{print $2}')
SNAP=$(ls -d "$HOME/.cache/huggingface/hub/models--${BASE//\//--}/snapshots/"*/ | head -1)
BEST=$(grep -o 'Iter [0-9]*: Val loss [0-9.]*' "$T/runs/$NAME.log" | awk '$2!="1:"{print $2, $5}' | sort -k2 -n | head -1 | cut -d: -f1)
A="$T/runs/$NAME-adapter"
mkdir -p "$A-best"; cp "$A/adapter_config.json" "$A-best/"; cp "$A/$(printf '%07d' "$BEST")_adapters.safetensors" "$A-best/adapters.safetensors"
echo "best checkpoint: iter $BEST"
(cd "$T" && .venv/bin/python -m mlx_lm fuse --model "$SNAP" --adapter-path "$A-best" --save-path "$M/tuned-$NAME")
echo "fused: $M/tuned-$NAME  (cleaner name: tuned-$NAME+lookup)"
