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
                } else if isScrubbing {
                    engine.seek(to: sliderTime)
                    isScrubbing = false
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

            Text(Self.clock(engine.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .leading)

            Toggle("Anime4K", isOn: $engine.settings.anime4KEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("超分将接入 Metal 管线；现在只记住开关。")

            Toggle("流畅档", isOn: $engine.settings.interpolationEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(true)
                .help("第二期接入系统插帧。")
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
