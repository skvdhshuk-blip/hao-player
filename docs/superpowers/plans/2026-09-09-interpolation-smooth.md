# Interpolation Fast + Quality Implementation Plan

> **For agentic workers:** Do not start until the spec is approved. Do not commit unless the user asks. No SVP / Vulkan / PyTorch in the .app.

**Goal:** 流畅档三态：关 / 快（VT low-latency） / 高质量（自维护 IFRNet-S）。都是源分辨率时间 2×，再进现有 Anime4K。

**Architecture:** `InterpolationMode` is the only setting. Session swaps `pipeline.interpolator`. Overload ladder: quality → fast → off.

**Tech Stack:** Swift 6, `VTFrameProcessor` + `VTLowLatencyFrameInterpolation`, CoreML IFRNet-S + optional Metal warp.

## Global Constraints

- Temporal 2×, spatial scale 1
- Copy: 关 / 快 / 高质量；不要写电影级光流
- Default `.off`
- startSession / ML load off the main thread
- 720p 24fps: fast must be realtime; quality should be, else drop to fast

## Files

- Create: `Sources/Enhance/VTInterpolationProcessor.swift`
- Create: `Sources/Enhance/IFRNetProcessor.swift`
- Create: `scripts/export_ifrnet_coreml.py` (dev only)
- Create: `Vendor/IFRNet/`, `Resources/LICENSES/IFRNet-MIT.txt`
- Modify: `EnhancementSettings`, `FrameProcessor`, passthrough, Anime4K (`reset`)
- Modify: `PlaybackSession`, `PlaybackEngine`, `PlayerChrome`
- Test: `Tests/InterpolationProcessorTests.swift`

## Tasks

1. Settings enum + `reset()` + fake interpolator / downgrade-ladder tests
2. VT 快档：能开、能 seek reset、失败降到关
3. IFRNet-S 高质量：离线导出 + decode-queue 推理；失败降到快档
4. Chrome 三态；过载梯子接上
5. `xcodegen` + tests + 720p 24fps 快/高质量手工对照
