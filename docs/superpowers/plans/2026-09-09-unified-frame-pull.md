# Unified Frame Pull Implementation Plan

> **For agentic workers:** Slice 1 only. Do not start Anime4K until mp4 and mkv both play through Metal passthrough.

**Goal:** mp4 and mkv share one `VideoSource.pull()` contract, one `PlaybackSession`, one `CAMetalLayer`.

**Architecture:** `AVFoundationSource` (AVAssetReader) and `FFmpegVTSource` (HaoReader) emit `MediaSample`. Session decodes on a background queue, clocks with `MediaClock`, plays PCM on `AVAudioEngine`, draws via `MetalPresenter`.

**Tech Stack:** Swift 6, AVFoundation, Metal / CoreImage blit, existing LGPL HaoReader.

## Global Constraints

- macOS 26+, arm64, sandbox entitlements unchanged
- No AVPlayer display or clock
- No interpolation, subtitles, or Anime4K in this slice
- `hao_reader` C API unchanged
- Do not commit unless the user asks

## Files

- Create: `Sources/Decode/MediaSample.swift`
- Create: `Sources/Decode/FFmpegVTSource.swift`
- Create: `Sources/Present/MetalPresenter.swift`
- Create: `Sources/Present/MetalView.swift`
- Create: `Sources/Playback/PlaybackSession.swift`
- Create: `Tests/AVFoundationSourceTests.swift`
- Create: `Tests/FFmpegVTSourceTests.swift`
- Modify: `Sources/Decode/VideoSource.swift`
- Modify: `Sources/Decode/AVFoundationSource.swift`
- Modify: `Sources/Playback/PlaybackEngine.swift`
- Modify: `Sources/UI/PlayerScreen.swift`
- Modify: `docs/ARCHITECTURE.md`
- Delete: `Sources/Playback/FFmpegPlaybackController.swift`
- Delete: `Sources/Present/SampleBufferView.swift`
- Delete: `Sources/Present/PlayerLayerView.swift`

## Tasks

### Task 1: Contract types

`MediaSample`, `AudioBuffer` (owns malloc PCM, `deinit` frees), new `VideoSource` (`open`, `seek(to: Double)`, `pull()`, `duration`, `hasAudio`, `sampleRate`).

### Task 2: FFmpegVTSource

Map `HaoReaderRead` kinds to `MediaSample`. Open/seek/close wrap C box.

### Task 3: AVFoundationSource

`AVAssetReader` video `420f` + audio 2ch interleaved float. Peek-interleave by PTS. Seek rebuilds reader.

### Task 4: MetalPresenter + PlaybackSession + Engine

CI blit letterbox to `CAMetalLayer`. Session is format-agnostic. Engine opens one source, no `AVPlayer`. UI shows `MetalView` when not idle.

### Task 5: Verify

`xcodegen generate` + unit tests + build. Manual: mp4 and sample mkv play/pause/seek.
