# Hao Player

Mac 上的超轻量本地播放器：一个 App，拖进去就能播。默认 Anime4K，可选流畅档。准备上 Mac App Store。

不是 IINA（通用播放器），不是 Infuse / SenPlayer（媒体库），不是追番套件，也不是 SVP 外挂。

## 现在能做什么

- 打开或拖放本地视频；关窗后可从「窗口 → 播放器」或 ⌘0 再打开
- mp4 / mov / m4v 走 AVFoundation；mkv / webm / avi / ts / flv 走自建 LGPL FFmpeg + VideoToolbox
- 默认 Anime4K Fast A 超分，可关
- 流畅档三态：关 / 快（系统补帧） / 高质量（IFRNet-S）。性能不足提示掉帧并保留选择；处理失败暂停，由用户重试或关闭失败功能
- 展示实际增强状态、性能详情与本地诊断；支持同帧超分对比和顺序流畅度对比
- 沙盒：只读用户选中的文件，书签续播

字幕还没做。插帧在源分辨率做完再进 Anime4K。高质量档的 720p24→48fps 持续目标尚未达标，详见 [验收报告](docs/reports/2026-09-09-enhancement.md)。

## 需要

- macOS 26+，Apple Silicon
- 从源码构建还要 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 构建

```bash
xcodegen generate
xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

本地运行必须带着沙盒 entitlements。关沙盒测通不算过。完整约束见 [AGENTS.md](AGENTS.md) 和 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 许可

自己的代码 [Apache-2.0](Resources/LICENSES/Apache-2.0.txt)。FFmpeg 仅 [LGPL 2.1](Resources/LICENSES/LGPL-2.1.txt)。Anime4K 与 IFRNet-S 为 MIT。详见应用内「许可证」。
