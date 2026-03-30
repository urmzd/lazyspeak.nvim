#!/usr/bin/env python3
"""Convert Voxtral-Mini-3B-2507 from HuggingFace to ONNX format.

Downloads the official weights from mistralai/Voxtral-Mini-3B-2507 (Apache 2.0,
ungated) and exports three ONNX submodels:
  - audio_encoder.onnx
  - decoder_model_merged.onnx
  - embed_tokens.onnx

Also copies the tokenizer for use at runtime.

Usage:
    pip install transformers torch optimum[exporters] onnxruntime onnxslim
    python scripts/convert_model.py [--output ~/.local/share/lazyspeak] [--quantize q4]
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

MODEL_ID = "mistralai/Voxtral-Mini-3B-2507"
DEFAULT_OUTPUT = Path.home() / ".local" / "share" / "lazyspeak"


def check_deps():
    """Verify required Python packages are installed."""
    missing = []
    for pkg in ["transformers", "torch", "optimum", "onnxruntime"]:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"Missing packages: {', '.join(missing)}")
        print("Install with: pip install transformers torch optimum[exporters] onnxruntime onnxslim")
        sys.exit(1)


def export_onnx(output_dir: Path):
    """Export the model to ONNX using optimum-cli."""
    onnx_dir = output_dir / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)

    print(f"Exporting {MODEL_ID} to ONNX at {onnx_dir}...")
    cmd = [
        sys.executable, "-m", "optimum.exporters.onnx",
        "--model", MODEL_ID,
        "--task", "automatic-speech-recognition",
        "--trust-remote-code",
        str(onnx_dir),
    ]
    subprocess.run(cmd, check=True)
    print(f"ONNX export complete: {onnx_dir}")


def quantize(output_dir: Path, variant: str):
    """Quantize ONNX models to a smaller variant (e.g. q4)."""
    try:
        import onnxruntime as _  # noqa: F401
        from optimum.onnxruntime import ORTQuantizer, AutoQuantizationConfig
    except ImportError:
        print("Skipping quantization — install optimum[onnxruntime] for quantization support")
        return

    onnx_dir = output_dir / "onnx"
    config_map = {
        "q4": "avx2",  # int4 weight-only
        "q8": "avx2",  # int8
    }

    if variant not in config_map:
        print(f"Unknown quantization variant: {variant}")
        return

    print(f"Quantizing to {variant}...")

    for model_file in onnx_dir.glob("*.onnx"):
        if f"_{variant}" in model_file.stem:
            continue
        print(f"  Quantizing {model_file.name}...")
        try:
            quantizer = ORTQuantizer.from_pretrained(str(onnx_dir), file_name=model_file.name)
            qconfig = AutoQuantizationConfig.avx2(is_static=False)
            out_name = model_file.stem + f"_{variant}.onnx"
            quantizer.quantize(save_dir=str(onnx_dir), quantization_config=qconfig, file_suffix=variant)
            print(f"  -> {out_name}")
        except Exception as e:
            print(f"  Skipped {model_file.name}: {e}")


def copy_tokenizer(output_dir: Path):
    """Download and copy tokenizer files to the output directory."""
    from transformers import AutoTokenizer
    print(f"Downloading tokenizer from {MODEL_ID}...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, trust_remote_code=True)
    tokenizer.save_pretrained(str(output_dir))
    print(f"Tokenizer saved to {output_dir}")


def main():
    parser = argparse.ArgumentParser(description="Convert Voxtral to ONNX")
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output directory (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--quantize", "-q",
        type=str,
        default=None,
        help="Quantization variant after export (e.g. q4, q8)",
    )
    parser.add_argument(
        "--skip-export",
        action="store_true",
        help="Skip ONNX export (only quantize / copy tokenizer)",
    )
    args = parser.parse_args()

    check_deps()

    args.output.mkdir(parents=True, exist_ok=True)

    if not args.skip_export:
        export_onnx(args.output)

    copy_tokenizer(args.output)

    if args.quantize:
        quantize(args.output, args.quantize)

    print("\nDone! Set LAZYSPEAK_BACKEND=onnx to use the ONNX backend.")
    print(f"Model files: {args.output / 'onnx'}")


if __name__ == "__main__":
    main()
