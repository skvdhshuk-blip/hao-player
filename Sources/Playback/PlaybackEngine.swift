import AppKit

enum PresentationMode {
    case idle
    case playing
}

final class PlaybackEngine: ObservableObject, @unchecked Sendable {
    @Published private(set) var mode: PresentationMode = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var title = ""
    @Published var settings = EnhancementSettings() {
        didSet { session.applyEnhancements(settings) }
    }
    @Published var errorMessage: String?
    @Published var isScrubbing = false
    @Published private(set) var isFullScreen = false

    let session = PlaybackSession()

    private var scopedURL: URL?
    private var accessing = false
    private var currentBookmark: Data?
    private let resume = ResumeStore()

    init() {
        session.onTick = { [weak self] time, playing in
            guard let self else { return }
            self.currentTime = time
            self.isPlaying = playing
        }
        session.onError = { [weak self] message in
            self?.errorMessage = message
            self?.isPlaying = false
        }
        session.applyEnhancements(settings)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard self?.isPlayerWindow(note.object) == true else { return }
            self?.isFullScreen = true
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard self?.isPlayerWindow(note.object) == true else { return }
            self?.isFullScreen = false
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.persistResume()
            self?.releaseScope()
            self?.session.shutdown()
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
        guard mode == .playing else { return }
        if session.isPlaying {
            session.pause()
        } else {
            session.play()
        }
        isPlaying = session.isPlaying
    }

    func seek(to time: Double) {
        guard mode == .playing else { return }
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
        persistResume()
        stopCurrentPlayback()

        let resolved = try FileOpening.resolve(bookmark)
        retainScope(resolved.url)
        guard accessing else {
            throw SourceError.scopedAccessFailed
        }

        let source: any VideoSource
        switch SourceRouter.kind(for: resolved.url) {
        case .unsupported:
            releaseScope()
            throw SourceError.unsupported(resolved.url.lastPathComponent)
        case .avFoundation:
            source = AVFoundationSource()
        case .ffmpeg:
            source = FFmpegVTSource()
        }
        try await source.open(resolved.url)
        session.open(source)
        duration = session.duration
        mode = .playing
        if let resumeTime, resumeTime > 0 {
            session.seek(to: resumeTime)
            currentTime = resumeTime
        } else {
            currentTime = 0
        }
        session.play()
        isPlaying = true
        title = displayName ?? resolved.url.lastPathComponent
        currentBookmark = bookmark
        errorMessage = nil
    }

    private func stopCurrentPlayback() {
        session.shutdown()
        mode = .idle
        isPlaying = false
    }

    private func retainScope(_ url: URL) {
        releaseScope()
        scopedURL = url
        accessing = url.startAccessingSecurityScopedResource()
    }

    private func releaseScope() {
        if accessing, let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        accessing = false
        scopedURL = nil
    }
}
