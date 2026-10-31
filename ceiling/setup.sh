#!/bin/zsh
# Build transcribe.cpp (Metal) and fetch the ceiling's extra recognizers into
# ~/Library/Caches/murmur-ceiling (about 15 GB; delete the folder to remove).
set -euo pipefail
CACHE=~/Library/Caches/murmur-ceiling
COMMIT=d0b949b
mkdir -p $CACHE/models
cd $CACHE
[[ -d transcribe.cpp ]] || git clone -q https://github.com/handy-computer/transcribe.cpp
cd transcribe.cpp
git fetch -q --depth 1 origin $COMMIT 2>/dev/null || true
git checkout -q $COMMIT
uv tool run --from cmake cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
uv tool run --from cmake cmake --build build -j 12 --target transcribe-cli >/dev/null
cd $CACHE/models
for m in whisper-large-v3 canary-qwen-2.5b granite-speech-4.1-2b; do
  f=$m-F16.gguf
  [[ -s $f ]] || curl -sL --fail -o $f "https://huggingface.co/handy-computer/$m-gguf/resolve/main/$f"
done
ls -la $CACHE/models
