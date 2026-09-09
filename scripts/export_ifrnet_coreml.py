#!/usr/bin/env python3
"""Dev-only: convert official IFRNet-S weights to CoreML. Not shipped in the .app."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import coremltools as ct
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from ifrnet_s import IFRNetS  # noqa: E402


def load_state(model: IFRNetS, checkpoint: Path) -> None:
    blob = torch.load(checkpoint, map_location="cpu", weights_only=False)
    if isinstance(blob, dict) and "state_dict" in blob:
        blob = blob["state_dict"]
    cleaned = {key.removeprefix("module."): value for key, value in blob.items()}
    model.load_state_dict(cleaned, strict=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "Resources" / "IFRNet_S.mlpackage",
    )
    parser.add_argument("--height", type=int, default=768)
    parser.add_argument("--width", type=int, default=1280)
    args = parser.parse_args()

    model = IFRNetS().eval()
    load_state(model, args.checkpoint)

    example = (
        torch.zeros(1, 3, args.height, args.width),
        torch.zeros(1, 3, args.height, args.width),
        torch.full((1, 1, 1, 1), 0.5),
    )
    traced = torch.jit.trace(model, example, strict=False)
    traced = torch.jit.freeze(traced)

    height = ct.RangeDim(lower_bound=64, upper_bound=1088, default=args.height)
    width = ct.RangeDim(lower_bound=64, upper_bound=1920, default=args.width)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="img0", shape=ct.Shape((1, 3, height, width))),
            ct.TensorType(name="img1", shape=ct.Shape((1, 3, height, width))),
            ct.TensorType(name="timestep", shape=(1, 1, 1, 1)),
        ],
        outputs=[ct.TensorType(name="imgt")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        if args.output.is_dir():
            import shutil

            shutil.rmtree(args.output)
        else:
            args.output.unlink()
    mlmodel.save(str(args.output))
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
