import AppKit
import CoreImage

enum PresentationMode {
    case idle
    case playing
}

@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var mode: PresentationMode = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var title = ""
    @Published var settings = EnhancementSettings() {
        didSet {
            session.applyEnhancements(settings)
            refreshEnhancementStatus()
        }
    }
    @Published private(set) var enhancementStatus = EnhancementStatus(anime4KEnabled: true, interpolation: .off)
    @Published private(set) var enhancementReport = EnhancementReport()
    @Published var enhancementFailure: EnhancementFailure?
    @Published var showEnhancementDetails = false
    @Published var showImageComparison = false
    @Published var comparisonImages: ComparisonImages?
    @Published var comparisonBusy = false
    @Published var comparisonMessage = ""
    @Published private(set) var motionComparing = false
    @Published private(set) var motionReports: [EnhancementReport] = []
    private var comparisonRestore: (time: Double, playing: Bool, settings: EnhancementSettings)?
    private var comparisonTask: Task<Void, Never>?
    @Published var errorMessage: String?
    @Published var isScrubbing = false
    @Published private(set) var isFullScreen = false

    let session = PlaybackSession()

    private var scopedURL: URL?
    private var accessing = false
    private var currentBookmark: Data?
    private let resume = ResumeStore()
    private var openGeneration = 0

    init() {
        session.onTick = { [weak self] time, playing in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time
                self.isPlaying = playing
                self.refreshEnhancementStatus()
            }
        }
        session.onError = { [weak self] message in
            MainActor.assumeIsolated {
                self?.errorMessage = message
                self?.isPlaying = false
            }
        }
        session.onEnhancementFailure = { [weak self] failure in
            MainActor.assumeIsolated {
                self?.enhancementFailure = failure
                self?.isPlaying = false
                self?.refreshEnhancementStatus()
            }
        }
        session.applyEnhancements(settings)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard self?.isPlayerWindow(window) == true else { return }
                self?.isFullScreen = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard self?.isPlayerWindow(window) == true else { return }
                self?.isFullScreen = false
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.isPlayerWindow(window) else { return }
                self.endComparison()
                self.openGeneration += 1
                if self.session.isPlaying { self.session.pause() }
                self.persistResume()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistResume()
                self?.session.shutdown()
                self?.releaseScope()
            }
        }
    }

    @MainActor
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsOtherFileTypes = true
        panel.message = "选择要播放的视频"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFile(url) }
    }

    @MainActor
    func openFile(_ url: URL) async {
        do {
            let bookmark = try FileOpening.bookmark(from: url)
            try await open(bookmark: bookmark, resumeTime: nil, displayName: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func openDroppedBookmark(_ drop: OpenedDrop) async {
        do {
            try await open(bookmark: drop.bookmark, resumeTime: nil, displayName: drop.displayName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func restoreIfNeeded() async {
        guard title.isEmpty, let record = resume.load() else { return }
        do {
            try await open(bookmark: record.bookmark, resumeTime: record.time)
        } catch {
            resume.clear()
        }
    }

    func togglePlay() {
        guard mode == .playing, comparisonRestore == nil else { return }
        if session.isPlaying {
            session.pause()
        } else if let failure = session.enhancementStatus.failure {
            enhancementFailure = failure
        } else {
            session.play()
        }
        isPlaying = session.isPlaying
    }

    func seek(to time: Double) {
        guard mode == .playing, comparisonRestore == nil else { return }
        let clamped = min(max(time, 0), max(duration, 0))
        session.seek(to: clamped)
        currentTime = clamped
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func toggleFullScreen() {
        playerWindow()?.toggleFullScreen(nil)
    }

    private func playerWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == WindowID.player || window.title == "Hao Player" || window.title == title
        }
    }

    private func isPlayerWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow else { return false }
        return window.identifier?.rawValue == WindowID.player || window.title == "Hao Player" || window.title == title
    }

    func persistResume() {
        guard let currentBookmark else { return }
        resume.save(bookmark: currentBookmark, time: currentTime, lastPath: title)
    }

    @MainActor
    private func open(bookmark: Data, resumeTime: Double?, displayName: String? = nil) async throws {
        endComparison()
        openGeneration += 1
        let generation = openGeneration
        let resolved = try FileOpening.resolve(bookmark)
        guard resolved.url.startAccessingSecurityScopedResource() else {
            throw SourceError.scopedAccessFailed
        }
        var transferred = false
        defer {
            if !transferred { resolved.url.stopAccessingSecurityScopedResource() }
        }
        let source: any VideoSource
        switch SourceRouter.kind(for: resolved.url) {
        case .unsupported:
            throw SourceError.unsupported(resolved.url.lastPathComponent)
        case .avFoundation:
            source = AVFoundationSource()
        case .ffmpeg:
            source = FFmpegVTSource()
        }
        do {
            try await source.open(resolved.url)
        } catch {
            guard generation == openGeneration else { return }
            throw error
        }
        guard generation == openGeneration else { return }
        persistResume()
        session.open(source)
        releaseScope()
        scopedURL = resolved.url
        accessing = true
        transferred = true
        duration = session.duration
        mode = .playing
        if let resumeTime, resumeTime > 0, resumeTime < duration {
            session.seek(to: resumeTime)
        }
        currentTime = session.currentTime
        session.play()
        isPlaying = session.isPlaying
        title = displayName ?? resolved.url.lastPathComponent
        currentBookmark = bookmark
        errorMessage = nil
        enhancementFailure = nil
        motionReports = []
        refreshEnhancementStatus()
    }

    private func refreshEnhancementStatus() {
        enhancementReport = session.metrics.snapshot()
        let status = enhancementReport.status
        if enhancementStatus != status { enhancementStatus = status }
    }

    var enhancementNotice: String? {
        if let failure = enhancementStatus.failure { return failure.errorDescription }
        if enhancementReport.consecutiveUnpresented >= 30 { return "当前未获得屏幕呈现确认，实际帧率统计暂不可用" }
        if enhancementStatus.performanceLimited { return "增强处理跟不上，当前存在掉帧；可手动关闭 Anime4K 或调整流畅档" }
        let effective = motionComparing ? enhancementReport.settings : settings
        var parts: [String] = []
        if effective.anime4KEnabled { parts.append("Anime4K：\(enhancementStatus.anime4KPhase.title)") }
        if effective.interpolation != .off { parts.append("流畅档：\(effective.interpolation.title) · \(enhancementStatus.interpolationPhase.title)") }
        return parts.isEmpty ? nil : parts.joined(separator: "　")
    }

    func keepPausedAfterFailure() {
        let failure = enhancementFailure
        if var saved = comparisonRestore {
            saved.playing = false
            comparisonRestore = saved
            endComparison()
        }
        session.pause()
        if let failure { session.metrics.fail(failure, epoch: session.seekEpoch) }
        enhancementFailure = nil
        isPlaying = false
    }

    func resolveEnhancementFailure(disable: Bool) {
        guard let failure = enhancementFailure else { return }
        endComparison()
        enhancementFailure = nil
        if disable {
            switch failure.stage {
            case .anime4K: settings.anime4KEnabled = false
            case .interpolation: settings.interpolation = .off
            case .presentation: break
            }
        }
        session.retryEnhancements()
        isPlaying = session.isPlaying
    }

    func exportEnhancementReport() {
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Hao Player Reports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "enhancement-\(Int(Date().timeIntervalSince1970)).json"
            let url = directory.appendingPathComponent(name)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let document = DiagnosticDocument(media: title, report: session.metrics.snapshot(), comparisons: motionReports)
            try encoder.encode(document).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }

    func beginImageComparison() {
        guard comparisonRestore == nil, let frame = session.lastOriginalFrame else { return }
        comparisonRestore = (currentTime, isPlaying, settings)
        session.pause()
        isPlaying = false
        showImageComparison = true
        comparisonBusy = true
        comparisonMessage = "正在生成同帧对比"
        comparisonTask = Task { [weak self] in
            do {
                let images = try await Task.detached(priority: .userInitiated) {
                    let processor = Anime4KProcessor()
                    let output = try processor.process(frame)[0]
                    let context = CIContext(options: [.workingColorSpace: NSNull()])
                    let before = CIImage(cvPixelBuffer: frame.pixelBuffer)
                    let after = CIImage(cvPixelBuffer: output.pixelBuffer)
                    guard let original = context.createCGImage(before, from: before.extent),
                          let enhanced = context.createCGImage(after, from: after.extent) else { throw Anime4KError.outputFailed }
                    return ComparisonImages(original: original, enhanced: enhanced, pts: frame.pts)
                }.value
                guard !Task.isCancelled else { return }
                self?.comparisonImages = images
                self?.comparisonBusy = false
                self?.comparisonMessage = "同一帧 · \(String(format: "%.3f", frame.pts)) 秒"
            } catch {
                self?.comparisonBusy = false
                self?.comparisonMessage = "对比生成失败：\(error.localizedDescription)"
            }
        }
    }

    func beginMotionComparison() {
        guard comparisonRestore == nil, settings.interpolation != .off else { return }
        comparisonRestore = (currentTime, isPlaying, settings)
        let selected = settings
        let start = min(currentTime, max(0, duration - 5))
        motionComparing = true
        motionReports = []
        comparisonTask = Task { [weak self] in
            guard let self else { return }
            // A comparison launched from the details sheet must wait for its dismissal.
            // Otherwise the compositor can keep the movie occluded for the entire sample.
            while self.playerWindow()?.attachedSheet != nil {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            }
            self.playerWindow()?.makeKeyAndOrderFront(nil)
            self.playerWindow()?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            for mode in [InterpolationMode.off, selected.interpolation] {
                guard !Task.isCancelled else { return }
                self.session.pause()
                var temporary = selected
                temporary.interpolation = mode
                self.comparisonMessage = mode == .off ? "对比 A：流畅档关闭" : "对比 B：流畅档\(mode.title)"
                self.session.applyEnhancements(temporary, purpose: "comparison-\(mode.rawValue)")
                self.session.seek(to: start)
                self.session.play()
                while self.session.isPlaying, self.session.currentTime < min(start + 5, self.duration), self.session.enhancementStatus.failure == nil {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    if Task.isCancelled { return }
                }
                let endedEarly = self.session.currentTime < min(start + 5, self.duration)
                self.session.pause()
                self.motionReports.append(self.session.metrics.snapshot())
                if self.session.enhancementStatus.failure != nil { return }
                if endedEarly {
                    self.comparisonRestore?.playing = false
                    self.endComparison()
                    self.comparisonMessage = "播放中断，对比未完成"
                    return
                }
            }
            self.comparisonMessage = "对比完成：可在性能详情中查看两次的实际状态和补帧数"
            self.endComparison()
            self.showEnhancementDetails = true
        }
    }

    func endComparison() {
        comparisonTask?.cancel()
        comparisonTask = nil
        guard let saved = comparisonRestore else { return }
        comparisonRestore = nil
        motionComparing = false
        showImageComparison = false
        comparisonImages = nil
        session.pause()
        session.applyEnhancements(saved.settings)
        session.seek(to: saved.time)
        if saved.playing, enhancementFailure == nil { session.play() }
        currentTime = saved.time
        isPlaying = session.isPlaying
    }

    private func releaseScope() {
        if accessing, let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        accessing = false
        scopedURL = nil
    }
}

struct ComparisonImages: @unchecked Sendable {
    let original: CGImage
    let enhanced: CGImage
    let pts: Double
}

private struct DiagnosticDocument: Encodable {
    let media: String
    let report: EnhancementReport
    let comparisons: [EnhancementReport]
    let displayFPS: Double
    let interpolatedShare: Double
    let dropRate: Double
    let footprintBytes = currentProcessFootprint()
    let created = Date()
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let architecture = "arm64"
    let applicationVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

    init(media: String, report: EnhancementReport, comparisons: [EnhancementReport]) {
        self.media = media
        self.report = report
        self.comparisons = comparisons
        displayFPS = report.displayFPS
        interpolatedShare = report.interpolatedShare
        dropRate = report.dropRate
    }
}
