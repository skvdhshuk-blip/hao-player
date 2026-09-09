# 统一拉帧 + Metal 出画

日期：2026-09-09  
状态：第一刀已实现（直通拉帧），第二刀 Anime4K 未开始  
决定：mp4/mov/m4v 与 mkv/webm/avi 走同一套 `pull()`，不再用 `AVPlayerLayer` / `AVSampleBufferDisplayLayer` 出画。

## 目标

打开任意已支持文件后：

- 视频从 `VideoSource.pull()` 取出带 PTS 的 `CVPixelBuffer`
- 音频从同一次 `pull()` 取出交错 stereo float PCM，只进 `AVAudioEngine`
- 进度只认 `MediaClock`（主机时钟，暂停冻结，不超过 duration）
- 画面只认一块 `CAMetalLayer`
- Anime4K 默认 Fast A；着色器失败则直通，不中断播放

验收：同一套暂停 / 空格 / 拖时间轴，对 sample mkv 和任意本地 mp4 行为一致；关 Anime4K 时画质等于源分辨率直通。

## 不做

- 插帧（「流畅档」开关保持禁用）
- 字幕 / libass
- 网络、媒体库、libmpv
- 把 Anime4KMetal 播放器壳或 GPL 源码搬进来
- 保留 `AVPlayer` 作为显示或时钟

## 合同

`VideoSource` 只做一件事：按时间顺序交出下一块媒体。

```
enum MediaSample {
    case video(VideoFrame)   // CVPixelBuffer + pts + duration
    case audio(AudioBuffer)  // 交错 stereo Float32、frameCount、sampleRate、pts
    case eof
}

protocol VideoSource: AnyObject {
    func open(_ url: URL) async throws
    func seek(to time: Double) throws
    func pull() throws -> MediaSample
    var duration: Double { get }
    var hasAudio: Bool { get }
    var sampleRate: Double { get }
}
```

规则：

- `pull()` 可阻塞在解码线程，不进主线程
- 一次调用只返回一种 sample；视频和音频由源自己交错
- `seek(t)` 之后：源丢弃内部旧缓冲；随后 `pull` 的视频 PTS ≥ t（关键帧只能更早时，由 session 丢掉 PTS < t − 0.05 的帧）
- 失败抛 `SourceError`，由引擎弹窗，不静默
- 像素格式：源出 `CVPixelBuffer`（优先 `420f`）。`MetalPresenter` 是唯一转换点，需要时转 `bgra8Unorm`，调用方不转
- 音频格式锁死：源出 2ch 交错 Float32，采样率跟文件；session 拆成非交错再喂 `AVAudioEngine`。无音频则 `hasAudio == false`，不建 audio graph，时钟仍走主机

两个实现，没有第三个：

| 类 | 文件 | 盒子 |
| --- | --- | --- |
| `AVFoundationSource` | mp4 / mov / m4v | `AVAssetReader` 视频轨 + 音频轨 |
| `FFmpegVTSource` | mkv / webm / avi / ts | 现有 `HaoReader` C 盒 |

`SourceRouter` 不变。`HaoReaderRead` 的 `HAO_VIDEO / HAO_AUDIO / HAO_EOF` 原样映射到 `MediaSample`。

## 数据流

```
书签 → 打开 URL
  → SourceRouter
  → VideoSource.open
  → 解码队列循环 VideoSource.pull
        视频 → 有界队列（约 12 帧）→ PlaybackPipeline → Metal 按 MediaClock 出画
        音频 → AVAudioEngine（标准非交错 float，入队前拆左右）
  → 暂停：冻 MediaClock + pause player node，解码停读
  → seek：清空队列、source.seek、stop/play node、重锚 MediaClock
```

`PlaybackEngine` 仍是唯一编排：打开、书签、错误、设置。不再按格式分 `PresentationMode.avPlayer / ffmpeg`，只留 `idle | playing`。

`FFmpegPlaybackController` 改名为 `PlaybackSession`，与格式无关：持有当前 `VideoSource`、时钟、音频图、`MetalPresenter`。

`PlaybackPipeline`：插帧固定 `PassthroughProcessor`；超分在开关打开且 GPU 程序可用时用 Anime4K Fast A，否则直通。

## 组件

**`AVFoundationSource`**  
`AVAssetReader` + 两条 `AVAssetReaderTrackOutput`。视频要 `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`。音频在源内重采样/混成 2ch 交错 Float32 再交出。`AVAssetReader` 不能回退：`seek` 必须 cancel 再建一条 reader，从 `t` 起读。

**`FFmpegVTSource`**  
只包 `HaoReaderOpen/Read/Seek/Close`。Swift 仍只见 `void *`。PCM 所有权：`pull` 交出指针，`PlaybackSession` 用完 `free`。

**`PlaybackSession`**  
搬现控制器的 `Transport`、`MediaClock`、主线程 `AVAudioEngine`、单一定时器。出画改为 `MetalPresenter.draw(pixelBuffer)`，不再建 `CMSampleBuffer`。

**`MetalPresenter`**  
一块 `CAMetalLayer`，`videoGravity` 等价 letterbox。只做直通 blit + letterbox。窗口 resize 只改 drawable 尺寸，不改源分辨率。Anime4K 接到 `PlaybackPipeline`，见 `2026-09-09-anime4k-fast-a-design.md`。

**Anime4K（第二刀）**  
默认 `EnhancementSettings.anime4KEnabled = true`，preset `fastA`。着色器自己维护，许可证 MIT，写进 Licenses。禁止搬 IINA / Anime4KMetal 播放器壳。编译或运行失败：该次会话改直通，底栏开关可保持开，不弹致命错误。

## 错误

| 情况 | 行为 |
| --- | --- |
| 打开失败 / 不支持 | 现有对话框，停在 idle |
| `pull` 解码失败 | 停播放，对话框，保留最后一帧 |
| 无音频 | 只走主机时钟，不建 audio graph |
| Anime4K 失败 | 直通，继续播 |
| 作用域书签失效 | 现有「重新打开或拖进来」 |

## 测试

- `AVFoundationSource`：对仓库内或临时小 mp4 打开、`pull` 至少一帧视频、seek 后 PTS 前进
- `FFmpegVTSource`：对现有 sniff 夹具或 sample 路径打开（无真实 mkv 时只测封装映射：kind 转换）
- `MediaClock`：保持现有用例
- `SourceRouter`：不变
- 不测 GPU 像素比对；第二刀只测「关开关必走直通」

## 实现刀法

1. **直通拉帧**：合同 + 两个 Source + Session + Metal 直通。删掉 `AVPlayer` 出画和 `AVSampleBufferDisplayLayer`。mp4 与 mkv 都能播、暂停、seek。
2. **Anime4K Fast A**：接到 `PlaybackPipeline` 超分位。默认开。失败直通。

第一刀没过，不开始第二刀。

## 与现状的关系

- 打开 / 拖放 / 书签 / 沙盒 / `FileDropCatcher` 不动
- `MediaClock` 不动
- `hao_reader.c` 公开 API 不动；只加 Swift 盒
- `docs/ARCHITECTURE.md` 里「第一期可用 AVPlayer 显示」作废，以本文为准
