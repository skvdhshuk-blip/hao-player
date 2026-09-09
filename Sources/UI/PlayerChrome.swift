import SwiftUI

struct PlayerChrome: View {
    @EnvironmentObject private var engine: PlaybackEngine
    @State private var sliderTime = 0.0
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                engine.togglePlay()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("空格暂停或继续")
            .accessibilityLabel(engine.isPlaying ? "暂停" : "播放")

            Text(Self.clock(isScrubbing ? sliderTime : engine.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)

            Slider(
                value: $sliderTime,
                in: 0...max(engine.duration, 0.1)
            ) { editing in
                if editing {
                    isScrubbing = true
                    engine.isScrubbing = true
                } else if isScrubbing {
                    engine.seek(to: sliderTime)
                    isScrubbing = false
                    engine.isScrubbing = false
                }
            }
            .onAppear {
                sliderTime = engine.currentTime
            }
            .onChange(of: engine.currentTime) { _, time in
                if !isScrubbing {
                    sliderTime = time
                }
            }
            .accessibilityLabel("播放进度")

            Text(Self.clock(engine.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .leading)

            Toggle("Anime4K", isOn: $engine.settings.anime4KEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("官方 Fast A 超分。关闭则源分辨率直通。")
                .accessibilityLabel("Anime4K 超分")

            Picker("流畅档", selection: $engine.settings.interpolation) {
                Text("关").tag(InterpolationMode.off)
                Text("快").tag(InterpolationMode.fast)
                Text("高质量").tag(InterpolationMode.quality)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .help("快是系统低延迟补帧，高质量是 IFRNet。")
            .accessibilityLabel("流畅档")

            Button {
                engine.toggleFullScreen()
            } label: {
                Image(systemName: engine.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("全屏")
            .accessibilityLabel(engine.isFullScreen ? "退出全屏" : "全屏")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(16)
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let remain = total % 60
        return String(format: "%02d:%02d", minutes, remain)
    }
}
