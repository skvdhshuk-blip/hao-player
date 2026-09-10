# 增强效果与持续性能验收

验收基线：Apple M5 Pro / 48GB / macOS 26.6.2。使用 Apple Development 签名、保持沙盒开启的 Release 构建。其他芯片的兼容性不等同于相同性能承诺。

| 组合 | 源规格 | 实际显示目标 | 完整增强 P95 上限 |
|---|---|---|---|
| Anime4K | 1080p24 / 30 | 24 / 30fps，实际显示 2× 分辨率增强结果 | 41.7 / 33.3ms |
| 快档 | 1080p24 / 30 | 48 / 60fps | 41.7 / 33.3ms |
| Anime4K + 快档 | 1080p24 / 30 | 48 / 60fps | 41.7 / 33.3ms |
| 高质量 | 720p24 | 48fps | 41.7ms |
| Anime4K + 高质量 | 720p24 | 记录实测，本轮不承诺实时 | 记录实测 |

每个必达组合预热后连续测量至少 600 秒：实际显示帧率 ≥ 目标的 98%，丢帧率 < 1%，完整增强 P95 严格低于源帧间隔。短测通过不等于持续验收通过。高质量未达标时必须单独列为未完成。

## 统计口径

- `settings` 是用户选择；`status` 是当前运行结果。初始化处理器不会使状态变成“已生效”；必须收到当前会话增强帧的正数 `presentedTime`。
- `submitted` 是渲染提交次数；`presentationCallbacks` 是呈现回调次数；`unpresentedCallbacks` 记录返回零的回调，不能算作已显示。窗口被遮挡、最小化或不在当前显示空间时不得据此宣称处理性能不达标，应在可见窗口重测。
- `presented`、`presentedInterpolated`、`presentedEnhanced` 只在屏幕呈现回调确认后计数；24fps 的 2× 目标是 48fps。
- 首次完整处理耗时单列。首次处理后 2 秒为预热期；暂停不累计测量时长和帧数。跳转、切片、改变设置开启新测量段，旧回调按会话标识隔离。
- `temporaryCleanup` 测量增强结果入队后退出自动释放池的时间；`processingWithCleanup` 包含增强、入队及释放。当前持续验收以这个合计作为 P95 门槛，旧报告的 `total` 只含增强计算，不能直接当成新的完整处理周期。
- `stages` 的均值、最大值和 P95 覆盖整个测量段，采用 0.1ms 直方图，不只统计最后几秒。输入转换、模型、输出转换包含于插帧，不能再与插帧重复相加。
- 分别报告过时源帧跳过、增强输出迟到丢弃和显示未呈现；源帧跳过按所选倍帧目标折算缺失输出。源帧率来自全部解码源帧的时间戳，不以处理速度代替。
- 原图/增强图使用同一原始帧、相同显示尺寸；流畅度 A/B 顺序播放同一 5 秒片段，不并行运行两条管线。对比报告具有独立 `purpose`，不混入普通播放段。

## 可重复的本地验收

准备脚本只创建测试素材，不改 Downloads 中的原视频。开发阶段使用的 ffmpeg 不进入应用，也不是用户运行时依赖。

```bash
scripts/run_enhancement_acceptance.sh prepare
# 20 秒用于检查路径和候选性能，不作为正式达标证据。
HAO_ACCEPTANCE_SECONDS=20 scripts/run_enhancement_acceptance.sh
# 默认每个组合测量 600 秒，按顺序运行，避免 GPU 相互竞争。
scripts/run_enhancement_acceptance.sh
# 只重测受影响组合。
HAO_ACCEPTANCE_CASE=both-1080p30 scripts/run_enhancement_acceptance.sh
```

持续验收脚本使用 `ENHANCEMENT_ACCEPTANCE` 编译条件生成独立 Release 应用，仅增加本地验收入口，调用与产品相同的解码、增强和显示代码；禁用历史文件自动续播，避免双路抢占 GPU。它不经过 XCTest 注入，签名保留 sandbox、只读用户文件和作用域书签权限，Apple Development 自动添加 get-task-allow。普通产品构建不包含验收入口。必须核对生成的 entitlements，不能把 XCTest 宿主注入的临时权限当作正常权限。

验收窗口置于前方避免遮挡。屏幕固定 60 Hz，窗口 960×540 点、2× backing scale；测试后恢复原屏幕刷新设置。七个必达组合各测 600 秒，额外的高质量 + Anime4K 测 60 秒，仅报告，不纳入实时承诺。测试失败保留 JSON，不允许切换算法、降低分辨率或跳过 GPU/模型后宣称成功。

自动回归单独运行：

```bash
xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/hao-enhancement-tests \
  -skip-testing:HaoPlayerTests/PerformanceAcceptanceTests test
# 保留真实中间帧的可选素材测试（不用于持续性能判定）
TEST_RUNNER_HAO_ACCEPTANCE_DIR="$HOME/Library/Containers/app.hao.HaoPlayer/Data/Library/Application Support/EnhancementAcceptance" \
  xcodebuild -scheme HaoPlayer -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/hao-enhancement-tests \
  -only-testing:HaoPlayerTests/PerformanceAcceptanceTests/testNaturalFrameComparison test
```

验收程序每 5 秒采样进程实际内存占用（`phys_footprint`）。30 秒后相对稳定期初值增长超过 2 GiB，立即保留报告、终止该轮并判为未通过；应用意外退出也会让脚本失败，不能继续空等或把缺失报告算成功。该保护只用于验收入口。

输入及每 5 秒更新的报告位于应用沙盒的 `Library/Application Support/EnhancementAcceptance`。1080p 素材来自 Downloads 的 1920×1080 视频，转换为固定 24/30fps 的 15 秒片段并重复封装至 630 秒；720p 素材来自 surfing MKV，统一为 24fps。素材含重复接点，不是原生十分钟长镜头。

`testNaturalFrameComparison` 保留真实中间帧，将左右两帧分别交给系统快档和 IFRNet-S，保存补帧与真实帧比较。MAE 只是像素误差证据，需结合运动、遮挡、纹理和场景切换视觉检查，不能据一条样例宣称某算法普遍更优。

## 运行规则

- 快档统一使用 `VTFrameRateConversionConfiguration`（normal），按系统要求的像素格式创建缓冲区，支持满足格式条件的解码缓冲区直接输入。不会静默切换为另一种插帧算法。
- 解码后台任务每次读取与增强都有独立 `autoreleasepool`，及时释放 Core ML / Core Image 临时对象；显示队列及插帧上一帧仍由强引用持有，不回收仍在使用的画面。
- 高质量使用随包 IFRNet-S 图像模型，保留源分辨率和原有 64 像素补边规则；只在模型需要时补边，输出裁回原尺寸。开发转换/一致性验证由 `export_ifrnet_coreml.py`、`validate_ifrnet_image.py` 完成。
- 性能不足不自动降低选择；丢弃过时输入后重置相邻帧关系，继续以所选效果处理较新的画面，避免画面永久停住。
- 算法处理失败暂停音画，用户决定重试或关闭失败功能后继续。保持暂停后再次点播放会重新提供处理入口。
- 诊断报告通过界面导出到应用自己的文稿目录并在 Finder 中显示，不增加文件写入或网络权限。

本轮实现、完整测量和内存修复证据见 [增强验收记录](reports/2026-09-09-enhancement.md)。
