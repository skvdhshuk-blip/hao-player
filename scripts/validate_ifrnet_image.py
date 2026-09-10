#!/usr/bin/env python3
"""Compare tensor and image Core ML exports with identical RGB samples (dev only)."""
import argparse
import json
import time
from pathlib import Path
import coremltools as ct
import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--image-model', type=Path, default=Path('Resources/IFRNet_S.mlpackage'))
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
reference = ct.models.MLModel(str(args.reference))
image_model = ct.models.MLModel(str(args.image_model))
rng = np.random.default_rng(20260909)
results = []
for h, w in [(64, 64), (128, 128), (768, 1280)]:
    a = rng.integers(0, 256, (h, w, 3), dtype=np.uint8)
    b = np.roll(a, 4, axis=1)
    timing = {}
    outputs = {}
    for name, model in [('tensor', reference), ('image', image_model)]:
        feed = {'timestep': np.full((1, 1, 1, 1), .5, dtype=np.float32)}
        for key, pixels in [('img0', a), ('img1', b)]:
            feed[key] = Image.fromarray(pixels) if name == 'image' else pixels.transpose(2, 0, 1)[None].astype(np.float32) / 255
        durations = []
        for _ in range(4):
            start = time.perf_counter()
            prediction = model.predict(feed)['imgt']
            durations.append((time.perf_counter() - start) * 1000)
        timing[name] = {'cold_ms': durations[0], 'warm_ms': durations[1:]}
        outputs[name] = np.array(prediction.convert("RGB")).astype(float) if name == 'image' else prediction[0].transpose(1, 2, 0).astype(float) * 255
    diff = np.abs(outputs['tensor'] - outputs['image'])
    results.append({'width': w, 'height': h, 'mean_abs_rgb_255': float(diff.mean()), 'max_abs_rgb_255': float(diff.max()), 'timing': timing})
    print(json.dumps(results[-1]), flush=True)
args.output.write_text(json.dumps(results, indent=2))
if any(r['mean_abs_rgb_255'] > 1 or r['max_abs_rgb_255'] > 4 for r in results):
    raise SystemExit('Image conversion consistency threshold exceeded')
