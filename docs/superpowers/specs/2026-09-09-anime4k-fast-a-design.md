# Anime4K Fast A

日期：2026-09-09  
状态：已实现  
决定：超分只接 `PlaybackPipeline.upscaler`。官方 v4 Fast Mode A，产出 2× `CVPixelBuffer`，`MetalPresenter` 仍只做 letterbox。失败切直通，不中断播放。

## 目标

- 默认开 Anime4K，preset 只有这一刀要实现的 `fastA`
- 开：源帧 → Fast A → 2× 帧进显示队列 → letterbox 出画
- 关：画质等于现在的源分辨率直通（同一块 `CVPixelBuffer` 身份不变）
- 着色器编译或 GPU 失败：该次会话改直通；底栏开关可保持开；不弹致命错误
- mp4 / mkv 同一条 `PlaybackSession`，暂停 / 空格 / seek 行为不变

## 不做

- Fast B/C、HQ A/B/C（枚举可留，全部当未实现，不得偷偷跑别的链）
- 插帧、字幕、OSD
- 按窗口尺寸动态超分（不在 Presenter 里跑着色器）
- 搬 IINA / Anime4KMetal / 任何播放器壳
- 像素级 GPU golden 图比对

本刀取代统一拉帧文档里「第二刀在同一 drawable 上跑 Fast A」那句；出画层继续只 blit。

## 合同

`FrameProcessor` 不变：一帧进，零或多帧出。超分恒为 1 出 1，PTS / duration 原样拷贝。

```
PlaybackPipeline.process(frame)
  = interpolator.process(frame)   // 本刀固定 PassthroughProcessor
    .flatMap { upscaler.process($0) }
```

`upscaler` 只有两个实现：

| 类 | 何时 |
| --- | --- |
| `PassthroughProcessor` | 开关关、尚未编译、本会话已失败 |
| `Anime4KProcessor` | 开关开且 GPU 程序可用 |

`Anime4KProcessor` 只做一件事：源 `CVPixelBuffer` → 宽高各 ×2 的 `32BGRA` `CVPixelBuffer`。调用方不转像素格式。输入可以是 `420v` / `420f` / `BGRA`。

官方 v4 **Fast Mode A** 的 pass 以 [bloc97/Anime4K](https://github.com/bloc97/Anime4K) 文档里的 Fast Mode A 清单为唯一事实源，不得自创第四个 pass。当前对应：

1. `ClampHighlights`
2. `Restore_CNN_M`
3. `Upscale_CNN_x2_M`

若上游 Fast A 清单用 `S` 档 CNN，按上游改名，不改「只做 Fast A、只 2×」这条。着色器自行移植成 `.metal`，许可证文本进 `Resources/LICENSES/Anime4K-MIT.txt`。禁止复制 Anime4KMetal 工程或播放器壳。

## 数据流

```
VideoSource.pull .video
  → dropBefore 门槛（已有）
  → PlaybackPipeline.process     // 解码队列，不上主线程
  → videoFrames（仍最多约 12）
  → VideoDisplay.take + MetalPresenter.draw
```

开关在播放中途变化：已经在队列里的帧不回炉；下一帧按新开关处理。不重建 session、不 seek。

`PlaybackEngine.settings` 是开关的唯一事实源。`PlaybackSession` 只读「当前该不该超分」，不自己持久化。

## 组件

**`Anime4KProcessor`**  
持有一条 Metal 命令链和中间纹理。懒编译：第一次 `process` 时建 PSO。编译失败或 `process` 抛错 → 处理器标记失效，之后 `process` 直接返回原帧（等价直通），由 session 把 `pipeline.upscaler` 换回 `PassthroughProcessor`。

**`PlaybackSession`**  
入队前调用 `pipeline.process`。捕获超分错误：该帧改直通入队，本会话不再走 Anime4K。`shutdown` 不强制释放 GPU 设备；下一文件 `open` 可重新尝试编译（新会话，失败标记清掉）。

**`PlaybackEngine`**  
`settings.anime4KEnabled` 变化时告诉 session 换 `upscaler`。默认 `true` / `fastA` 已有，不改产品默认。

**`MetalPresenter`**  
不改合同。2× BGRA 当普通帧 letterbox。

**许可证 UI**  
`LicensesView` 去掉「Anime4KMetal 运行时尚未嵌入」。只写 Anime4K MIT 已嵌入。

## 错误

| 情况 | 行为 |
| --- | --- |
| Metal 设备不存在 / PSO 编译失败 | 直通，开关保持开 |
| 单帧 `process` 失败 | 该帧直通入队，本会话此后直通 |
| 开关关闭 | 立刻换 `PassthroughProcessor`，已入队的 2× 帧播完即恢复源尺寸 |
| `pull` 解码失败 | 仍走现有对话框，与超分无关 |

没有 OSD 模块，本刀不新做 OSD。

## 测试

- 关开关：`pipeline` 输出帧的 `pixelBuffer` 与输入是同一实例
- 开开关但处理器标记失败：输出与输入同一实例，不抛到 UI
- 默认设置仍是 `anime4KEnabled == true`、`fastA`
- 不测 GPU 像素；有真实 GPU 的构建以「能播、能关、关后是直通」手工验收

## 验收

1. sample mkv 与任意本地 mp4：默认开着能播，画面比直通更利（720p 尤其明显）
2. 关掉 Anime4K：马上变源清晰度（最多隔队列里那几帧）
3. 再打开：新帧重新超分，不必点进度条
4. 空格 / 拖时间轴 / 换片：不回归上一刀的黑屏或「旧画面」
