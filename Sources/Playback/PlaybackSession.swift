import AVFoundation
import CoreVideo
import QuartzCore

final class PlaybackSession: @unchecked Sendable {
    private enum Transport {
        case stopped
        case playing
        case paused
    }

    private enum Timing {
        static let displayInterval = 1.0 / 120.0
        static let uiInterval = 0.25
        static let lateFrame = 0.18
        static let earlyFrame = 0.03
        static let videoBacklog = 12
        static let decodeIdle = 0.03
        static let decodeWait = 0.01
        static let seekSlop = 0.05
    }

    let presenter = MetalPresenter()
    let pipeline = PlaybackPipeline()

    private let anime4K = Anime4KProcessor()
    private let passthrough = PassthroughProcessor()
    private var anime4KEnabled = true
    private var upscalerFailed = false
    private var source: (any VideoSource)?
    private let decodeQueue = DispatchQueue(label: "hao.player.decode")
    private let lock = NSLock()
    private let enhanceLock = NSLock()
    private var videoFrames: [VideoFrame] = []
    private var decodeRunning = false
    private var transport: Transport = .stopped
    private var hostAnchor = CACurrentMediaTime()
    private var timeAnchor = 0.0
    private var clockTimer: Timer?
    private var lastUIPublish = 0.0
    private var audioEngine: AVAudioEngine?
    private var audioNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var hasAudio = false
    private var sampleRate = 48000.0
    private var pendingSeek: Double?
    private(set) var dropBefore = 0.0

    private(set) var duration = 0.0
    private(set) var currentTime = 0.0
    var onTick: ((Double, Bool) -> Void)?
    var onError: ((String) -> Void)?

    var isPlaying: Bool { transport == .playing }

    func applyEnhancements(_ enabled: Bool) {
        enhanceLock.lock()
        anime4KEnabled = enabled
        refreshUpscaler()
        enhanceLock.unlock()
    }

    func open(_ source: VideoSource) {
        shutdown()
        enhanceLock.lock()
        upscalerFailed = false
        anime4K.resetFailure()
        refreshUpscaler()
        enhanceLock.unlock()
        self.source = source
        duration = source.duration
        hasAudio = source.hasAudio
        sampleRate = source.sampleRate > 0 ? source.sampleRate : 48000
        if hasAudio {
            attachAudio()
        }
    }

    func play() {
        timeAnchor = currentTime
        hostAnchor = CACurrentMediaTime()
        transport = .playing
        onMain {
            guard let engine = self.audioEngine, let node = self.audioNode else { return }
            if !engine.isRunning {
                try? engine.start()
            }
            if !node.isPlaying {
                node.play()
            }
        }
        startClock()
        startDecodeLoop()
        publishTime(playing: true)
    }

    func pause() {
        currentTime = mediaTime()
        transport = .paused
        onMain { self.audioNode?.pause() }
        publishTime(playing: false)
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), max(duration, 0))
        lock.lock()
        videoFrames.removeAll()
        pendingSeek = clamped
        dropBefore = clamped
        lock.unlock()
        currentTime = clamped
        timeAnchor = clamped
        hostAnchor = CACurrentMediaTime()
        onMain {
            self.audioNode?.stop()
            if self.transport == .playing {
                self.audioNode?.play()
            }
        }
        if transport != .stopped {
            startDecodeLoop()
        }
        publishTime(playing: isPlaying)
    }

    func shutdown() {
        transport = .stopped
        decodeRunning = false
        lock.lock()
        videoFrames.removeAll()
        pendingSeek = nil
        dropBefore = 0
        lock.unlock()
        onMain {
            self.clockTimer?.invalidate()
            self.clockTimer = nil
            self.audioNode?.stop()
            self.audioEngine?.stop()
            self.audioEngine = nil
            self.audioNode = nil
            self.audioFormat = nil
        }
        let closed = DispatchSemaphore(value: 0)
        decodeQueue.async {
            self.source = nil
            closed.signal()
        }
        closed.wait()
        lock.lock()
        videoFrames.removeAll()
        pendingSeek = nil
        dropBefore = 0
        lock.unlock()
        currentTime = 0
        duration = 0
    }

    private func startClock() {
        if clockTimer != nil { return }
        lastUIPublish = 0
        let timer = Timer(timeInterval: Timing.displayInterval, repeats: true) { [weak self] _ in
            self?.displayTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func displayTick() {
        guard transport == .playing else { return }
        let now = mediaTime()
        currentTime = now
        lock.lock()
        let frame = VideoDisplay.take(
            now: now,
            frames: &videoFrames,
            ready: presenter.isReady,
            late: Timing.lateFrame,
            early: Timing.earlyFrame
        )
        lock.unlock()
        if let frame, !presenter.draw(frame.pixelBuffer) {
            lock.lock()
            videoFrames.insert(frame, at: 0)
            lock.unlock()
        }
        let host = CACurrentMediaTime()
        if host - lastUIPublish >= Timing.uiInterval {
            lastUIPublish = host
            publishTime(playing: true)
        }
    }

    private func publishTime(playing: Bool) {
        onTick?(currentTime, playing)
    }

    private func startDecodeLoop() {
        if decodeRunning { return }
        decodeRunning = true
        decodeQueue.async { [weak self] in
            self?.runDecode()
        }
    }

    private func runDecode() {
        while decodeRunning, let source {
            lock.lock()
            let backlog = videoFrames.count
            lock.unlock()
            if backlog > Timing.videoBacklog {
                Thread.sleep(forTimeInterval: Timing.decodeWait)
                continue
            }
            lock.lock()
            let seekTo = pendingSeek
            pendingSeek = nil
            lock.unlock()
            if let seekTo {
                do {
                    try source.seek(to: seekTo)
                } catch {
                    fail(error)
                    break
                }
            }
            if transport != .playing {
                Thread.sleep(forTimeInterval: Timing.decodeIdle)
                continue
            }
            do {
                switch try source.pull() {
                case .eof:
                    decodeRunning = false
                case .video(let frame):
                    if frame.pts + Timing.seekSlop >= dropBefore {
                        let outgoing = enhance(frame)
                        lock.lock()
                        videoFrames.append(outgoing)
                        lock.unlock()
                    }
                case .audio(let packet):
                    scheduleAudio(packet)
                }
            } catch {
                fail(error)
                break
            }
        }
    }

    private func refreshUpscaler() {
        pipeline.upscaler = (anime4KEnabled && !upscalerFailed) ? anime4K : passthrough
    }

    private func enhance(_ frame: VideoFrame) -> VideoFrame {
        enhanceLock.lock()
        defer { enhanceLock.unlock() }
        do {
            return try pipeline.process(frame)[0]
        } catch {
            upscalerFailed = true
            refreshUpscaler()
            return frame
        }
    }

    private func fail(_ error: Error) {
        decodeRunning = false
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    private func attachAudio() {
        onMain {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 2) else {
                self.hasAudio = false
                return
            }
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.audioFormat = format
            self.audioEngine = engine
            self.audioNode = node
        }
    }

    private func onMain(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func scheduleAudio(_ packet: AudioBuffer) {
        guard let format = audioFormat, let node = audioNode, packet.frameCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.frameCount)),
              let channels = buffer.floatChannelData else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(packet.frameCount)
        let left = channels[0]
        let right = channels[1]
        for i in 0..<packet.frameCount {
            left[i] = packet.pcm[i * 2]
            right[i] = packet.pcm[i * 2 + 1]
        }
        node.scheduleBuffer(buffer)
    }

    private func mediaTime() -> Double {
        MediaClock.now(
            paused: transport != .playing,
            frozen: currentTime,
            anchor: timeAnchor,
            elapsed: CACurrentMediaTime() - hostAnchor,
            duration: duration
        )
    }
}

enum VideoDisplay {
    static func take(
        now: Double,
        frames: inout [VideoFrame],
        ready: Bool,
        late: Double,
        early: Double
    ) -> VideoFrame? {
        guard ready else { return nil }
        while frames.count > 1, let first = frames.first, first.pts < now - late {
            frames.removeFirst()
        }
        if let first = frames.first, first.pts <= now + early {
            return frames.removeFirst()
        }
        return nil
    }
}
