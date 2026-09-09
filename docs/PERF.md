# 1080p 双开性能手测

成功标准：同一条 **1080p 24fps** 片子，沙盒开着，**Anime4K Fast A + 流畅档「快」** 实时跟上。enhance 中位小于源间隔（约 41.7ms），显示队列不顶满 12，不因过载把快档降成关。

Instruments 看 `hao.player.enhance` 与 `hao.player.present` 两个 signpost。

## 片子

固定一条 1080p24 番剧（AVFoundation 的 mp4 或 FFmpeg 的 mkv 各测一次更好）。四种开关用同一文件、同一窗口尺寸。

## 四种开关

1. 双关：Anime4K 关，流畅档关。基线直通，确认不花屏。
2. 仅 Anime4K：默认超分，流畅档关。
3. 仅快档：Anime4K 关，流畅档「快」。
4. 双开（过线项）：Anime4K 开 + 流畅档「快」。至少播 2 分钟。

高质量档（IFRNet-S）不作为本轮实时目标。

## Instruments

1. Time Profiler：decode 线程是否堵在 `waitUntilCompleted` / CI。
2. Metal System Trace：Anime4K 20 pass 之后不应再出现大块 CI render。

## 过线

- 双开 enhance 中位 < 41.7ms
- 播放过程流畅档保持「快」，不会自动降到关
- 关 Anime4K / 关插帧画面正常、不崩
