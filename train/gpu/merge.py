#!/usr/bin/env python3
"""Fold a LoRA adapter (sft.py --bits 16) into its base model and save a full bf16 model, ready for
`mlx_lm convert -q` on a Mac (train/gpu/README.md).

  merge.py --model Qwen/Qwen3-4B-Instruct-2507 --adapter RUN/best --out MERGED
"""
import argparse, os, shutil, sys
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out)
    if (out / "config.json").exists():
        print("already merged: %s" % out)
        return 0
    import torch
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer
    base = AutoModelForCausalLM.from_pretrained(a.model, dtype=torch.bfloat16, device_map={"": "cpu"})
    model = PeftModel.from_pretrained(base, a.adapter).merge_and_unload()
    tmp = out.with_name(out.name + ".partial")
    shutil.rmtree(tmp, ignore_errors=True)
    model.save_pretrained(tmp, safe_serialization=True, max_shard_size="2GB")
    AutoTokenizer.from_pretrained(a.adapter).save_pretrained(tmp)
    os.replace(tmp, out)
    print("merged: %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
