# AGENTS.md - hao-player

## 1. 项目定位

Hao Player 是面向 Mac App Store 的超轻量本地视频播放器：一个 `.app`，拖进去就能播，默认 Anime4K，可选系统插帧。

不是 IINA（通用播放器）、不是 Infuse/SenPlayer（媒体库）、不是 AnimacX（追番套件）、不是 SVP 外挂。

技术栈：Swift 6 / macOS 26+ / Apple Silicon only。解码走 AVFoundation + 自建 LGPL FFmpeg + VideoToolbox。增强走自己的 Metal / `VTFrameProcessor` 管线。禁止 libmpv、禁止 GPL 源码、禁止 Homebrew 运行时依赖。

当前阶段：脚手架 + mp4（AVFoundation）+ mkv/webm/avi（LGPL FFmpeg + VideoToolbox）。Anime4K / 插帧按 `docs/ARCHITECTURE.md` 分期，不要提前做。

FFmpeg 库在 `Vendor/FFmpeg/dist`。源码树在 `Vendor/FFmpeg/src`（不入库）。重编：`scripts/build_ffmpeg_lgpl.sh`。

## 2. 命令

工程用 XcodeGen 生成，不要手改 `HaoPlayer.xcodeproj`。

```bash
xcodegen generate
xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

本地运行必须带着 `HaoPlayer.entitlements`（沙盒开着）。关沙盒测通不算过。

签名：`project.yml` 里写了 `DEVELOPMENT_TEAM: M2WM2NJP68` 和 Apple Development。不要改回 ad-hoc（`-`），Xcode 会丢掉沙盒键。entitlements 的三项权限写在 `project.yml` 的 `entitlements.properties`，跑 `xcodegen generate` 会回写 `HaoPlayer.entitlements`。

## 3. 目录地图 / 架构

```
Sources/App        应用入口、单一 Window
Sources/Playback   PlaybackEngine：唯一编排点
Sources/Decode     VideoSource 协议；AVFoundationSource；HaoReader C 盒
Sources/Enhance    FrameProcessor；设置；日后 Anime4K / VT 插帧
Sources/Present    AVPlayerLayer / AVSampleBufferDisplayLayer / 日后 CAMetalLayer
Sources/UI         极简 chrome：打开、进度、两个开关
Sources/Legal      Licenses、书签/续播
Resources          Info.plist、PrivacyInfo、LICENSES
Vendor             第三方源与 XCFramework，不进 GPL
```

管线顺序写死：**解码 → 源分辨率插帧 → Anime4K → 字幕 → 显示**。UI 只改开关，不碰解码。

## 4. 代码风格 / 接口契约

- 播放会话 `@MainActor`。安全作用域书签必须在 drop 闭包里生成，再跳主线程。
- `VideoSource` 只有两个实现：`AVFoundationSource`、`FFmpegVTSource`。不要加 mpv 回退。
- 不支持的格式必须弹对话框，禁止静默失败。
- 产品文案：插帧叫「流畅档」，不要写「电影级光流」。
- UI 中文；系统控件；底栏用材质，不要做成媒体库。

## 5. 工作流硬约束

- 许可证：自己的代码 Apache-2.0。FFmpeg 仅 LGPL，禁止 `--enable-gpl` / `--enable-nonfree`。
- Entitlements 只允许：`app-sandbox`、`files.user-selected.read-only`、`files.bookmarks.app-scope`。禁止 JIT / RWX / `disable-library-validation` / 网络（第一期）。
- 书签 key 必须是 `com.apple.security.files.bookmarks.app-scope`（带 `files.`）。
- 所有嵌入库同一 Team 签名，禁止链 `/opt/homebrew`。
- 不主动 commit；用户要求才提交。

## 6. 已知陷阱 / 不要做

- 不要用 `AVPlayerView` 当主界面，滤镜以后插不进去。
- 不要 fork IINA / Glass Player / Anime4KMetal 的播放器壳。
- 不要为「关窗后打不开」回归 `WindowGroup`；必须能从菜单「窗口 → 播放器」或 ⌘0 再打开。
- 不要在 drop 闭包结束后再 `startAccessingSecurityScopedResource`，scope 已经死了。
- 不要用开发者证书 + 关沙盒当验收。
