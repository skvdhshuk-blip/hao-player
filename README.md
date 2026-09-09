# Hao Player

Mac 上的超轻量本地播放器：一个 App，拖进去就能播，默认 Anime4K，可选系统插帧。准备上 Mac App Store。

当前仓库还在搭第一期脚手架。完整约束见 [AGENTS.md](AGENTS.md) 和 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 需要

- macOS 26+，Apple Silicon
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 构建

```bash
xcodegen generate
xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' build
```

## 许可

源代码 Apache-2.0。第三方组件各自保留上游许可证，见应用内「许可证」。
