import AVFoundation
import AppKit

enum PresentationMode {
    case idle
    case avPlayer
    case ffmpeg
}

final class PlaybackEngine: ObservableObject, @unchecked Sendable {
    @Published private(set) var player = AVPlayer()
    @Published private(set) var mode: PresentationMode = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var title = ""
    @Published var settings = EnhancementSettings()
    @Published var errorMessage: String?

    var displayLayer: AVSampleBufferDisplayLayer { ffmpeg.displayLayer }

    private let ffmpeg = FFmpegPlaybackController()
    private var source: (any VideoSource)?
    private var scopedURL: URL?
    private var accessing = false
    private var currentBookmark: Data?
    private var timeObserver: Any?
    private let resume = ResumeStore()

    init() {
        installTimeObserver()
        ffmpeg.onTick = { [weak self] time, playing in
            guard let self else { return }
            self.currentTime = time
            self.isPlaying = playing
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.persistResume()
            self?.releaseScope()
            self?.ffmpeg.shutdown()
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
        switch mode {
        case .idle:
            return
        case .avPlayer:
            if player.currentItem == nil { return }
            if player.rate == 0 {
                player.play()
                isPlaying = true
            } else {
                player.pause()
                isPlaying = false
            }
        case .ffmpeg:
            if ffmpeg.isPlaying {
                ffmpeg.pause()
            } else {
                ffmpeg.play()
            }
            isPlaying = ffmpeg.isPlaying
        }
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), max(duration, 0))
        switch mode {
        case .idle:
            return
        case .avPlayer:
            let cm = CMTime(seconds: clamped, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        case .ffmpeg:
            ffmpeg.seek(to: clamped)
        }
        currentTime = clamped
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
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

        switch SourceRouter.kind(for: resolved.url) {
        case .unsupported:
            releaseScope()
            throw SourceError.unsupported(resolved.url.lastPathComponent)
        case .avFoundation:
            try await openAVFoundation(resolved.url, resumeTime: resumeTime)
        case .ffmpeg:
            try openFFmpeg(resolved.url, resumeTime: resumeTime)
        }

        title = displayName ?? resolved.url.lastPathComponent
        currentBookmark = bookmark
        errorMessage = nil
    }

    @MainActor
    private func openAVFoundation(_ url: URL, resumeTime: Double?) async throws {
        let next = AVFoundationSource()
        try await next.open(url)
        let item = try next.makePlayerItem()
        source = next
        player.replaceCurrentItem(with: item)
        duration = next.duration.seconds.isFinite ? next.duration.seconds : 0
        mode = .avPlayer
        if let resumeTime, resumeTime > 0 {
            seek(to: resumeTime)
        } else {
            currentTime = 0
        }
        player.play()
        isPlaying = true
    }

    @MainActor
    private func openFFmpeg(_ url: URL, resumeTime: Double?) throws {
        try ffmpeg.open(url)
        duration = ffmpeg.duration
        mode = .ffmpeg
        if let resumeTime, resumeTime > 0 {
            ffmpeg.seek(to: resumeTime)
            currentTime = resumeTime
        } else {
            currentTime = 0
        }
        ffmpeg.play()
        isPlaying = true
    }

    private func stopCurrentPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        ffmpeg.shutdown()
        source = nil
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

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.mode == .avPlayer else { return }
            self.currentTime = time.seconds
            self.isPlaying = self.player.rate != 0
        }
    }
}
