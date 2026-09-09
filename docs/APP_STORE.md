# Mac App Store 提交清单

仓库能做到工程合规。创建 App、上传截图、点 Submit 必须你本人在 App Store Connect 操作。

联系邮箱（许可证书面提供、Connect 支持）：`support@hao.app`。若要换邮箱，同时改 `Sources/Legal/LicensesView.swift` 与 `docs/store/`。

## 你需要事先有的东西

1. 付费 Apple Developer Program，Team `M2WM2NJP68`
2. Xcode 26+，已登录该 Apple ID
3. **Apple Distribution** 证书（Xcode → Settings → Accounts → Manage Certificates）
4. 一条 1080p24 本地片子，用来拍截图
5. 把 [docs/store/privacy-policy.md](store/privacy-policy.md) 挂到可公开 URL（GitHub 仓库页面即可）

日常 `project.yml` 保持 `CODE_SIGN_IDENTITY: Apple Development`。不要改成 Distribution，否则本地调试会丢 `get-task-allow`。

## Connect 建应用

1. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) 注册 Bundle ID：`app.hao.HaoPlayer`（macOS App）
2. [App Store Connect](https://appstoreconnect.apple.com) → 我的 App → 添加 macOS App
   - 名称：Hao Player
   - 主要语言：简体中文
   - Bundle ID：`app.hao.HaoPlayer`
   - SKU：自定，例如 `hao-player-macos`
3. 年龄分级：无不良内容（本地播放器，用户自备文件）
4. 出口合规：选择不使用豁免加密之外的加密。Info.plist 已设 `ITSAppUsesNonExemptEncryption = false`
5. 隐私政策 URL：填你托管的 `privacy-policy.md`
6. 类别：照片与视频 / 视频播放
7. 价格：自定
8. 把 [docs/store/metadata.zh-Hans.md](store/metadata.zh-Hans.md) 贴进名称、副标题、描述、关键词
9. 审核备注贴 [docs/store/review-notes.md](store/review-notes.md)

## 截图（你来拍，仓库不造图）

Mac 截图按 Connect 当前要求的分辨率上传。至少 3 张：

1. 空窗口：「打开文件或拖进来」
2. 1080p + Anime4K 开着
3. 流畅档打在「快」

用系统全屏截图。不要写「电影级光流」，不要承诺字幕。

## 本地打包

```bash
xcodegen generate
scripts/collect_lgpl_relink_artifacts.sh
scripts/archive_mas.sh
```

`archive_mas.sh` 会：

1. Archive
2. 用 `ExportOptions-MAS.plist` 导出（`method = app-store-connect`）
3. 断言没有 `get-task-allow`、只有三项沙盒键、FFmpeg dylib 已签名

`exportArchive` 若报 `No profiles for 'app.hao.HaoPlayer'`：先在 Identifiers 里注册该 Bundle ID，再补 Apple Distribution 证书。Automatic 签名会在导出时拉 Mac App Store 描述文件。也可以：打开 `HaoPlayer.xcodeproj` → Product → Archive → Distribute App → App Store Connect。

## 上传与提交

1. Organizer 或 Transporter 上传导出的包
2. 在 Connect 选构建版本 `1.0.0`
3. 再对一遍店描：仅本地、无网络、无字幕、高质量档有分辨率上限、macOS 26+ / Apple Silicon
4. 提交审核

## 提交前工程验收

- `xcodegen generate && xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test`
- 沙盒运行 1080p24，Anime4K + 流畅档快档，至少 2 分钟不卡、不自动降到关
- 关 Anime4K / 关插帧不花屏
- `build/lgpl-relink-7.1.1/` 非空（版本号以 `Vendor/FFmpeg/dist/VERSION` 为准）
