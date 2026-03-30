#!/usr/bin/env python3
"""Convert Voxtral-Mini-3B-2507 from HuggingFace to GGUF format.

Downloads the official weights from mistralai/Voxtral-Mini-3B-2507 (Apache 2.0,
ungated) and converts to GGUF Q4_K_M for use with llama-server.

Requires: pip install gguf transformers torch mistral-common
Also requires: llama-quantize (from llama.cpp)

Usage:
    python scripts/convert_model.py [--output ~/.local/share/lazyspeak]
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

MODEL_ID = "mistralai/Voxtral-Mini-3B-2507"
DEFAULT_OUTPUT = Path.home() / ".local" / "share" / "lazyspeak"
MODEL_NAME = "voxtral-mini-3b-q4_k_m.gguf"


def find_convert_script() -> Path:
    """Find convert_hf_to_gguf.py from llama.cpp installation."""
    # Check common locations
    candidates = [
        # Homebrew
        *Path("/opt/homebrew/Cellar/llama.cpp").glob("*/bin/convert_hf_to_gguf.py"),
        # Linux package
        Path("/usr/share/llama.cpp/convert_hf_to_gguf.py"),
        # In PATH
        shutil.which("convert_hf_to_gguf.py"),
    ]
    for c in candidates:
        if c and Path(c).exists():
            return Path(c)

    print("convert_hf_to_gguf.py not found.")
    print("Install llama.cpp: brew install llama.cpp")
    sys.exit(1)


def find_quantize() -> Path:
    """Find llama-quantize binary."""
    path = shutil.which("llama-quantize")
    if path:
        return Path(path)
    print("llama-quantize not found. Install llama.cpp: brew install llama.cpp")
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Convert Voxtral HF → GGUF Q4_K_M")
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output directory (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()

    output_dir = args.output
    output_dir.mkdir(parents=True, exist_ok=True)

    final_path = output_dir / MODEL_NAME
    if final_path.exists() and final_path.stat().st_size > 1_000_000:
        print(f"Model already exists: {final_path}")
        return

    convert_script = find_convert_script()
    quantize_bin = find_quantize()

    f16_path = output_dir / "voxtral-mini-3b-f16.gguf"

    # Step 1: Convert HF → GGUF F16 (downloads model remotely)
    if not f16_path.exists() or f16_path.stat().st_size < 1_000_000:
        print(f"Converting {MODEL_ID} → GGUF F16...")
        cmd = [
            sys.executable, str(convert_script),
            "--remote", MODEL_ID,
            "--outfile", str(f16_path),
            "--outtype", "f16",
        ]
        subprocess.run(cmd, check=True)
        print(f"✓ F16 model: {f16_path} ({f16_path.stat().st_size / 1e9:.1f} GB)")

    # Step 2: Quantize F16 → Q4_K_M
    print(f"Quantizing → Q4_K_M...")
    cmd = [str(quantize_bin), str(f16_path), str(final_path), "Q4_K_M"]
    subprocess.run(cmd, check=True)
    print(f"✓ Q4_K_M model: {final_path} ({final_path.stat().st_size / 1e9:.1f} GB)")

    # Step 3: Clean up F16 intermediate
    if final_path.exists() and final_path.stat().st_size > 1_000_000:
        f16_path.unlink(missing_ok=True)
        print(f"✓ Cleaned up F16 intermediate")

    print(f"\nDone! Model ready at: {final_path}")


if __name__ == "__main__":
    main()
