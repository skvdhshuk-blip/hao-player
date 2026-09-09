# Hao Player 架构

## 产品

一个能上 Mac App Store 的本地播放器：拖放即播，默认 Anime4K，可选系统插帧。无媒体库、弹幕、转码、网盘。

## 管线

```
用户选中的文件
  → Security-Scoped Bookmark
  → VideoSource（AVFoundation 或 FFmpeg+VT）
  → CVPixelBuffer @ 源分辨率
  → FrameInterpolator（可关；快=VT 低延迟 / 高质量=自维护 IFRNet-S，皆源分辨率 2×）
  → FrameUpscaler（Anime4K Metal）
  → libass 按显示分辨率叠加
  → CAMetalLayer
音频走独立时钟，视频追音频。
```

顺序不可反。先超分再插帧禁止。两档都开时，中端 M 芯必须能自动降到 Fast 或关插帧。

## 模块

| 单元 | 职责 | 失败时 |
| --- | --- | --- |
| `ScopedBookmarkStore` | 把用户选中的 URL 变成可续播书签 | 读失败当新打开，不扫盘 |
| `VideoSource` | 产出带 PTS 的帧 | 不支持则抛错，UI 弹窗 |
| `InterpolationRuntime` | 流畅档盒子与过载梯子（高质量→快→关） | 当前档失败则换下一档，本帧直通 |
| `PlaybackPipeline` | 超分位（Anime4K） | 超分失败则直通 |
| `PlaybackEngine` | 打开/时钟/状态 | 源失败则停在错误态 |
| `PlayerChrome` | 打开、进度、Anime4K、插帧 | 不直接操作解码器 |

显示走统一拉帧 + `CAMetalLayer`（`AVFoundationSource` / `FFmpegVTSource`）。Anime4K 接在 `PlaybackPipeline` 超分位。

## 实现分期

1. **已完成**：沙盒工程 + 打开/拖放/续播 + 关窗可再开 + Licenses。
2. **已完成**：LGPL FFmpeg 共享库 + `HaoReader` C 盒 + mkv/webm/avi/ts。
3. **已完成**：统一 `VideoSource.pull()` + `PlaybackSession` + Metal 直通出画（mp4/mov/m4v 与 mkv/webm/avi/ts 同一条时钟）。
4. **已完成**：Anime4K Fast Mode A（`PlaybackPipeline` 超分，失败直通）。
5. **已完成**：流畅档三态——关 / 快（`VTLowLatencyFrameInterpolation`） / 高质量（自维护 IFRNet-S）。皆源分辨率时间 2×，先于 Anime4K。过载：高质量→快→关。见 `docs/superpowers/specs/2026-09-09-interpolation-smooth-design.md`。禁止 SVP、完整 RIFE 4.25、ncnn-Vulkan。

## App Store

- arm64 / macOS 26+
- 无 GPL、无 libmpv、无 LuaJIT
- entitlements 与开发、提交同一份
- 应用内 Licenses + 店描 LGPL 书面提供
