# 流畅档（快 / 高质量）

日期：2026-09-09  
状态：高质量盒子已定为 IFRNet-S  
决定：插帧只接 `PlaybackPipeline.interpolator`。两档都是 **源分辨率时间 2×**，再交给 Anime4K。

| 档 | 盒子 | 定位 |
| --- | --- | --- |
| 关 | `PassthroughProcessor` | 默认 |
| 快 | `VTLowLatencyFrameInterpolation` | 系统低延迟补一帧 |
| 高质量 | 自维护 **IFRNet-S**（[ltkong218/IFRNet](https://github.com/ltkong218/IFRNet) MIT 权重 + CoreML，warp 不足用自己的 Metal） | 比 VT 快档稳（大动作少融化），比完整 RIFE 轻，冲 720p 实时 |

禁止 SVP / mpv / PyTorch / Vulkan / Homebrew。文案不要写「电影级光流」。

## 目标

- 底栏「流畅档」是三态：关 / 快 / 高质量。不是两个独立开关。
- 两档都是相邻源帧之间插 1 帧（t = 0.5），分辨率不变
- seek / 换片：`reset()`，丢掉上一帧参考
- 当前档加载或单帧失败：先降到下一档（高质量→快→关），开关显示可以暂时不动，不弹致命错误
- 过载同样按 **高质量 → 快 → 关** 降，Anime4K 尽量留着
- 快档验收：720p 24/30fps 实时
- 高质量验收：720p 24fps 实时；1080p 或与 Anime4K 同开允许降到快档

## 不做

- SVP、VapourSynth、libmpv、ncnn-Vulkan、MoltenVK、PyTorch、MLX 运行时
- 运行时下载权重；禁止把 [ifrnet-ncnn-vulkan](https://github.com/nihui/ifrnet-ncnn-vulkan) 或任何 Vulkan 运行时塞进 `.app`
- 高质量档不用完整 RIFE 4.25 / RIFE Lite、不用 IFRNet / IFRNet-L、不用 EMA-VFI、不用 GMFSS（转码级，日后第三档另开规格）
- AMT-S（CC BY-NC，不能上架）
- VT 空间放大、追 120Hz、4× / 多 phase
- 字幕 / 新 OSD

## 设置合同

`interpolationEnabled` 布尔作废，改成：

```
enum InterpolationMode: String {
    case off
    case fast
    case quality
}

struct EnhancementSettings {
    var anime4KEnabled: Bool        // 默认 true
    var interpolation: InterpolationMode  // 默认 .off
}
```

UI：`Picker` 或等价分段，「流畅档」标签 + 关 / 快 / 高质量。Help：快是系统低延迟补帧，高质量是 IFRNet。

## 处理器合同

```
protocol FrameProcessor: AnyObject {
    func process(_ frame: VideoFrame) throws -> [VideoFrame]
    func reset()
}
```

两个真盒子（`VTInterpolationProcessor`、`IFRNetProcessor`）对外行为相同：

| 输入 | 输出 |
| --- | --- |
| 第一帧 / `reset` 后第一帧 | `[current]` |
| 之后每一源帧 | `[mid, current]`，`mid.pts = (prev + curr) / 2` |
| 失败 | 抛错；session 降档，本帧 `[current]` |

`PlaybackPipeline` 仍是 `interpolator` 再 `upscaler`。Session 只换 `pipeline.interpolator` 实例，不改管线顺序。

### 快（VT）

- `VTLowLatencyFrameInterpolationConfiguration`：源宽高，**1** 个中间帧，**spatial scale = 1**
- `startSession` 只在解码队列（官方：加载模型可能超过一帧）
- previous + source，phase `0.5`
- 分辨率变化：重建 session

### 高质量（IFRNet-S）

- 只用官方 **IFRNet-S** 权重（MIT，随包进 `Vendor/IFRNet/`），不要 S 以外的变体
- 离线转 CoreML（`scripts/export_ifrnet_coreml.py`），用户机器不跑 Python
- `grid_sample` / 光流 warp 编不出来就用仓库里自己的 Metal warp；禁止 ncnn / Vulkan
- 加载和推理只在解码队列
- 分辨率变化：重建或动态输入，并 `reset`

## 数据流

```
pull.video
  → 当前档 interpolator     // 源分辨率，0 或 1 张中间帧
  → Anime4K 或直通
  → videoFrames
  → MediaClock + Metal
```

音频、时钟、`dropBefore` 不动。seek / `open` 调当前 interpolator 的 `reset()`。

## 过载与降档

连续 8 次 `process` 墙钟 > 源帧间隔的 80%：

1. 高质量 → 换成快（VT），并 `reset`
2. 已经是快 → 关插帧
3. Anime4K 不自动关

当前档 `startSession` / 模型失败：走同一条梯子，不静默黑屏。

## 许可证

- 自己的代码 Apache-2.0
- IFRNet：MIT，进 Licenses（`Resources/LICENSES/IFRNet-MIT.txt`）
- VT 是系统框架，不用随包许可证
- 禁止 SVP 二进制或密钥

## 测试

- `.off` 且 Anime4K 关：输出 buffer 与输入同一实例
- 假插帧器：第二帧两个 PTS，`reset` 后下一帧 1 个
- 默认 `interpolation == .off`
- 降档梯子：高质量失败后 session 用的是快档盒子（可用假盒子测）
- 不测 VT / IFRNet 像素黄金图

## 验收

1. 720p 24fps：快档明显更顺；高质量应比快档更稳（大动作少融化），seek 不把两场揉在一起
2. 只开插帧、关 Anime4K：分辨率仍是源分辨率
3. 两档超分+插帧都开：先插后超分；卡了按梯子降，不先关 Anime4K
4. 沙盒、无网、现有 entitlements 能播
