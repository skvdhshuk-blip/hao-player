import SwiftUI

struct EnhancementDetails: View {
    @EnvironmentObject private var engine: PlaybackEngine
    private var report: EnhancementReport { engine.enhancementReport }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("增强效果与性能").font(.title2)
                Spacer()
                Button("完成") { engine.showEnhancementDetails = false }
            }
            Text(engine.enhancementNotice ?? "增强已关闭").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("源视频", "\(report.sourceWidth)×\(report.sourceHeight) · \(number(report.sourceFPS)) fps")
                row("实际显示", "\(number(report.displayFPS)) fps · \(report.presented) 帧")
                row("补帧", "生成 \(report.generatedInterpolated) · 显示 \(report.presentedInterpolated) · 占比 \(number(report.interpolatedShare * 100))%")
                row("Anime4K", "实际显示 \(report.presentedEnhanced) 帧")
                row("丢帧", "源帧跳过 \(report.droppedSource) · 过晚 \(report.droppedLate) · 显示失败 \(report.droppedDisplay) · \(number(report.dropRate * 100))%")
                row("测量时长", "\(number(report.measuredSeconds)) 秒（首次处理后预热 2 秒，暂停不计时）")
                row("首次处理", "\(number(report.firstProcessMS ?? 0)) ms")
                row("队列", "当前 \(report.queueDepth) · 峰值 \(report.maxQueueDepth)")
                ForEach(["inputConversion", "model", "vtProcessing", "outputConversion", "interpolation", "anime4K", "total", "queueToScreen", "displayGPU"], id: \.self) { stage in
                    if let timing = report.stages[stage] {
                        row(stageTitle(stage), "平均 \(number(timing.meanMS)) ms · P95 \(number(timing.p95MS)) ms")
                    }
                }
            }.font(.system(.body, design: .monospaced))
            Text("P95：95% 的处理耗时不超过此值。显示帧率来自屏幕呈现回调；低于目标时不会自动降低效果。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(engine.motionReports.enumerated()), id: \.offset) { index, value in
                Text("对比 \(index == 0 ? "A" : "B") · \(value.settings.interpolation.title) · \(value.status.interpolationPhase.title) · 实际显示补帧 \(value.presentedInterpolated) · \(number(value.displayFPS)) fps")
                    .font(.caption)
            }
            HStack {
                Button("同帧画质对比") {
                    engine.showEnhancementDetails = false
                    engine.beginImageComparison()
                }.disabled(engine.session.lastOriginalFrame == nil)
                Button("5 秒流畅度对比") {
                    engine.showEnhancementDetails = false
                    engine.beginMotionComparison()
                }.disabled(engine.settings.interpolation == .off)
                Spacer()
                Button("导出诊断报告") { engine.exportEnhancementReport() }
            }
        }.padding(24).frame(width: 650)
    }

    private func number(_ value: Double) -> String { String(format: "%.1f", value) }
    private func row(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
    private func stageTitle(_ value: String) -> String {
        ["inputConversion": "输入转换", "model": "模型计算", "vtProcessing": "系统插帧处理", "outputConversion": "模型输出转换",
         "interpolation": "插帧合计", "anime4K": "Anime4K", "total": "完整增强", "queueToScreen": "入队到显示", "displayGPU": "显示 GPU"][value] ?? value
    }
}

struct ImageComparisonView: View {
    @EnvironmentObject private var engine: PlaybackEngine
    @State private var split = 0.5
    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("原始画面 ← 同帧对比 → Anime4K").font(.headline)
                Spacer()
                Button("完成") { engine.endComparison() }
            }
            Text(engine.comparisonMessage).font(.caption).foregroundStyle(.secondary)
            if let images = engine.comparisonImages {
                ScrollView([.horizontal, .vertical]) {
                    let width = 800 * zoom
                    let height = width * Double(images.original.height) / Double(images.original.width)
                    ZStack(alignment: .leading) {
                        Image(decorative: images.enhanced, scale: 1).resizable().frame(width: width, height: height)
                        Image(decorative: images.original, scale: 1).resizable().frame(width: width, height: height)
                            .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
                        Rectangle().fill(.white).frame(width: 2, height: height).offset(x: width * split)
                    }.frame(width: width, height: height)
                }.frame(height: 450).background(.black)
                HStack {
                    Text("对比分界")
                    Slider(value: $split, in: 0...1).accessibilityLabel("原图与增强图分界")
                    Picker("放大", selection: $zoom) {
                        Text("适应窗口").tag(1.0)
                        Text("2×").tag(2.0)
                        Text("4×").tag(4.0)
                    }.frame(width: 160)
                }
            } else {
                if engine.comparisonBusy { ProgressView() }
                Color.black.frame(height: 450)
            }
        }.padding(20).frame(width: 840)
    }
}
