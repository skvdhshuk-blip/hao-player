# Anime4K Fast A Implementation Plan

> **For agentic workers:** Inline execution in this session. Do not commit unless the user asks.

**Goal:** Default-on official Fast Mode A (Clamp + Restore_CNN_M + Upscale_CNN_x2_M) through `PlaybackPipeline.upscaler`, 2× BGRA frames, fail to passthrough.

**Architecture:** Decode-queue `pipeline.process` before enqueue. `MetalPresenter` stays letterbox. Settings live on `PlaybackEngine`.

**Tech Stack:** Swift 6, Metal compute, bloc97/Anime4K MIT GLSL ported to `.metal`.

## Global Constraints

- macOS 26+, arm64, sandbox unchanged
- No Anime4KMetal / IINA shell
- Only Fast A, only 2×
- No GPU golden images
- Do not commit unless asked
