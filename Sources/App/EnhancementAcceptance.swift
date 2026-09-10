#if ENHANCEMENT_ACCEPTANCE
import AppKit

/// Compiled only by the explicit acceptance build. No XCTest-injected entitlements.
@MainActor
final class EnhancementAcceptance {
    static let shared = EnhancementAcceptance()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    private func run() async {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnhancementAcceptance")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
            let cases: [(String, String, Bool, InterpolationMode, Double)] = [
                ("anime-1080p24", "1080p24.mp4", true, .off, 24),
                ("anime-1080p30", "1080p30.mp4", true, .off, 30),
                ("fast-1080p24", "1080p24.mp4", false, .fast, 48),
                ("fast-1080p30", "1080p30.mp4", false, .fast, 60),
                ("both-1080p24", "1080p24.mp4", true, .fast, 48),
                ("both-1080p30", "1080p30.mp4", true, .fast, 60),
                ("quality-720p24", "720p24.mkv", false, .quality, 48),
                ("quality-anime-720p24", "720p24.mkv", true, .quality, 48),
            ]
            var outcomes: [Outcome] = []
            for (name, filename, anime, mode, target) in cases where request.cases == nil || request.cases!.contains(name) {
                let session = PlaybackSession()
                session.applyEnhancements(EnhancementSettings(anime4KEnabled: anime, interpolation: mode))
                let source: any VideoSource = filename.hasSuffix("mkv") ? FFmpegVTSource() : AVFoundationSource()
                try await source.open(directory.appendingPathComponent(filename))
                session.open(source)
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
                defer { session.shutdown(); window.close() }
                window.isReleasedWhenClosed = false
                window.level = .floating
                window.title = "增强验收 · \(name)"
                window.contentView = MetalCanvas(presenter: session.presenter)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let screen = window.screen
                let required = name != "quality-anime-720p24"
                let duration = required ? request.seconds : min(request.seconds, 60)
                var memory: [[String: Double]] = []
                var settledFootprint: UInt64?
                let start = Date()
                var lastSave = Date.distantPast
                session.play()
                while session.isPlaying, Date().timeIntervalSince(start) < duration + 20 {
                    try await Task.sleep(for: .milliseconds(100))
                    let report = session.metrics.snapshot()
                    let footprint = currentProcessFootprint()
                    if Date().timeIntervalSince(start) >= 30, footprint > 0 {
                        if let baseline = settledFootprint, footprint > baseline + 2 * 1024 * 1024 * 1024 {
                            try encoder.encode(report).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
                            throw NSError(domain: "EnhancementAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "\(name): memory grew over 2 GiB after warmup (\(baseline) → \(footprint) bytes); acceptance aborted."])
                        }
                        if settledFootprint == nil { settledFootprint = footprint }
                    }
                    if Date().timeIntervalSince(lastSave) >= 5 {
                        try encoder.encode(report).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
                        memory.append(["elapsed": Date().timeIntervalSince(start), "footprint_bytes": Double(footprint)])
                        try encoder.encode(memory).write(to: directory.appendingPathComponent("\(name)-memory.json"), options: .atomic)
                        lastSave = Date()
                    }
                    if report.measuredSeconds >= duration || report.status.failure != nil { break }
                }
                session.pause()
                let report = session.metrics.snapshot()
                try encoder.encode(report).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
                let budget = (mode == .off ? 1000 : 2000) / target
                let passed = report.status.failure == nil && report.measuredSeconds >= 599.5
                    && report.displayFPS >= target * 0.98 && report.dropRate < 0.01
                    && (report.stages["total"]?.p95MS ?? .infinity) < budget
                    && (!anime || report.presentedEnhanced == report.presented)
                    && (mode == .off || report.interpolatedShare > 0.45)
                outcomes.append(Outcome(name: name, required: required, passed: required ? passed : nil,
                    displayFPS: report.displayFPS, dropRate: report.dropRate,
                    screen: screen?.localizedName ?? "unknown", scale: Double(screen?.backingScaleFactor ?? 0),
                    maximumRefreshRate: screen?.maximumFramesPerSecond ?? 0))
                try encoder.encode(outcomes).write(to: directory.appendingPathComponent("outcomes.json"), options: .atomic)
            }
            try Data("complete".utf8).write(to: directory.appendingPathComponent("finished.txt"), options: .atomic)
            NSApp.terminate(nil)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt"), options: .atomic)
            NSApp.terminate(nil)
        }
    }

    private struct Request: Decodable { var seconds: Double; var cases: [String]? }
    private struct Outcome: Encodable {
        var name: String; var required: Bool; var passed: Bool?
        var displayFPS: Double; var dropRate: Double
        var screen: String; var scale: Double; var maximumRefreshRate: Int
    }
}
#endif
