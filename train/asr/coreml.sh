#!/bin/zsh
# Convert a Parakeet Unified .nemo (stock or fine-tuned) to the Core ML bundles Murmur loads
# (offline 15 s encoder, int8; decoder; single-step joint; vocab.json), using FluidAudio's own
# conversion pipeline (mobius) at a pinned commit. Runs on a Mac (coremlcompiler). Usage:
#   train/asr/coreml.sh MODEL.nemo OUT_DIR
# Then copy OUT_DIR to ~/Library/Application Support/Murmur/models/NAME and bench it as
# recognizer "parakeet-unified@NAME" (or "parakeet-unified@NAME+vote").
set -euo pipefail
NEMO=${1:A}; OUT=${2:A}
MOBIUS_COMMIT=ade0f35ddc0e27b2b7c6c5c73a23eae38da7e29b
W=~/Library/Caches/parakeet-coreml
UV=${UV:-uv}
mkdir -p $W && cd $W
[[ -d mobius ]] || { curl -sL https://github.com/FluidInference/mobius/archive/$MOBIUS_COMMIT.tar.gz | tar -xz && mv mobius-$MOBIUS_COMMIT mobius; }
[[ -x env/bin/python ]] || { ${=UV} venv -q --python 3.11 env && ${=UV} pip install -q --python env/bin/python "torch==2.7.0" "coremltools>=9" "nemo_toolkit[asr]==3.0.0" "numpy<2.3" soundfile librosa huggingface-hub; }
B=$(mktemp -d $W/build.XXXX); mkdir -p $B/int8
cd mobius/models/stt/parakeet-unified-en-0.6b/coreml
$W/env/bin/python convert-coreml.py --nemo-path $NEMO --output-dir $B/fp16 --skip-streaming
# int8 per-channel weights on the offline encoder only (quantize_int8.py also expects streaming encoders).
$W/env/bin/python - $B <<'PY'
import sys, coremltools as ct
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
b = sys.argv[1]
cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel", dtype="int8"))
m = ct.models.MLModel(f"{b}/fp16/parakeet_unified_encoder.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)
linear_quantize_weights(m, cfg).save(f"{b}/int8/parakeet_unified_encoder.mlpackage")
PY
$W/env/bin/python stage_hf.py --coreml-dir $B/fp16 --int8-dir $B/int8 --output-dir $B/staged --nemo-path $NEMO
mkdir -p $OUT
for f in parakeet_unified_encoder_int8.mlmodelc parakeet_unified_decoder.mlmodelc parakeet_unified_joint_decision_single_step.mlmodelc; do
  rm -rf $OUT/$f; cp -R $B/staged/$f $OUT/
done
cp $B/staged/vocab.json $OUT/
[[ -f $B/staged/metadata.json ]] && cp $B/staged/metadata.json $OUT/
rm -rf $B
echo "converted: $OUT"
