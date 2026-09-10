import AppKit
import AVFoundation
import CoreVideo
import QuartzCore

final class PlaybackSession: @unchecked Sendable {
    private enum Transport {
        case stopped
        case playing
        case paused
        case ended
    }

    private enum Timing {
        static let uiInterval = 0.25
        static let lateFrame = 0.18
        static let earlyFrame = 0.03
        static let videoBacklog = 12
        static let decodeIdle = 0.03
        static let seekSlop = 0.05
    }

    let presenter = MetalPresenter()
    let pipeline = PlaybackPipeline()

    private let interpolation: InterpolationRuntime
    private let anime4K = Anime4KProcessor()
    private let passthrough = PassthroughProcessor()
    private var anime4KEnabled = true
    let metrics = EnhancementMetrics()
    private var requestedSettings = EnhancementSettings()
    private var pendingEnhancements = false
    private var pendingReset = false
    private var metricsPurpose = "playback"
    private var comparisonFrame: VideoFrame?
    private var source: (any VideoSource)?
    private let decodeQueue = DispatchQueue(label: "hao.player.decode")
    private let lock = NSLock()
    private let enhanceLock = NSLock()
    private var videoFrames: [VideoFrame] = []
    private var running = false
    private var state: Transport = .stopped
    private var sourceEnded = false
    private var previewPending = false
    private var buffering = false
    private var decodeDeadline = 0.0
    private var activity: NSObjectProtocol?
    private var lastMediaEnd = 0.0
    private var decodeRunning: Bool {
        get { lock.withLock { running } }
        set { lock.withLock { running = newValue } }
    }
    private var transport: Transport {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
    private var hostAnchor = CACurrentMediaTime()
    private var timeAnchor = 0.0
    private var displayLink: CADisplayLink?
    private var displayTarget: DisplayTickTarget?
    private var lastUIPublish = 0.0
    private var audioEngine: AVAudioEngine?
    private var audioNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var hasAudio = false
    private var audioPTSOrigin: Double?
    private var sampleRate = 48000.0
    private var pendingSeek: Double?
    private(set) var dropBefore = 0.0
    private(set) var seekEpoch = 0

    private(set) var duration = 0.0
    private(set) var currentTime = 0.0
    var onTick: ((Double, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onEnhancementFailure: ((EnhancementFailure) -> Void)?

    var isPlaying: Bool { transport == .playing }
    var enhancementStatus: EnhancementStatus { metrics.snapshot().status }
    var lastOriginalFrame: VideoFrame? { lock.withLock { comparisonFrame } }
    var queuedFramePTS: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return videoFrames.map(\.pts)
    }

    func publishEnhanced(_ outgoing: [VideoFrame], epoch: Int) {
        lock.lock()
        if epoch == seekEpoch {
            videoFrames.append(contentsOf: outgoing.map { frame in
                var value = frame
                value.trace.queuedAt = CACurrentMediaTime()
                return value
            })
            metrics.queued(epoch: epoch, count: videoFrames.count)
            for frame in outgoing { lastMediaEnd = max(lastMediaEnd, frame.pts + frame.duration) }
            if buffering, !outgoing.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard epoch == self.seekEpoch, self.buffering else { return }
                        self.buffering = false
                        self.timeAnchor = self.currentTime
                        self.hostAnchor = CACurrentMediaTime()
                        if self.state == .playing, self.audioPTSOrigin != nil { self.audioNode?.play() }
                    }
                }
            }
        }
        lock.unlock()
    }

    init(makeInterpolator: ((InterpolationMode) -> FrameProcessor)? = nil) {
        interpolation = InterpolationRuntime(make: makeInterpolator ?? PlaybackSession.defaultInterpolator)
    }

    func applyEnhancements(_ settings: EnhancementSettings, purpose: String = "playback") {
        lock.withLock {
            requestedSettings = settings
            pendingEnhancements = true
            metricsPurpose = purpose
        }
        if source != nil { seek(to: currentTime) }
        else { resetMetrics() }
    }

    private func resetMetrics() {
        let values = lock.withLock { (seekEpoch, requestedSettings, metricsPurpose) }
        metrics.reset(epoch: values.0, settings: values.1, purpose: values.2)
        metrics.setPlaying(isPlaying)
    }

    func retryEnhancements() {
        lock.withLock { pendingEnhancements = true }
        seek(to: currentTime)
        play()
    }

    func open(_ source: VideoSource) {
        shutdown()
        enhanceLock.lock()
        interpolation.restoreRequested()
        interpolation.reset()
        anime4K.resetFailure()
        refreshUpscaler()
        enhanceLock.unlock()
        resetMetrics()
        self.source = source
        duration = source.duration
        hasAudio = source.hasAudio
        sampleRate = source.sampleRate > 0 ? source.sampleRate : 48000
        if hasAudio {
            attachAudio()
        }
    }

    func play() {
        guard source != nil, enhancementStatus.failure == nil else { return }
        if transport == .ended || (duration > 0 && currentTime >= duration) {
            seek(to: 0)
        }
        timeAnchor = currentTime
        hostAnchor = CACurrentMediaTime()
        lock.withLock { if videoFrames.isEmpty { buffering = true } }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "本地视频播放")
        }
        transport = .playing
        metrics.setPlaying(true)
        onMain {
            guard let engine = self.audioEngine, let node = self.audioNode else { return }
            if !engine.isRunning {
                try? engine.start()
            }
            if self.lock.withLock({ self.audioPTSOrigin != nil && !self.buffering }), !node.isPlaying {
                node.play()
            }
        }
        startClock()
        startDecodeLoop()
        publishTime(playing: true)
    }

    func pause() {
        if isPlaying { currentTime = mediaTime() }
        transport = .paused
        endActivity()
        metrics.setPlaying(false)
        onMain { self.audioNode?.pause() }
        publishTime(playing: false)
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), max(duration, 0))
        lock.lock()
        videoFrames.removeAll()
        comparisonFrame = nil
        // At the endpoint decode the final frame, while retaining the requested UI time.
        let decodeTime = clamped >= duration ? max(0, duration - 0.1) : clamped
        pendingSeek = decodeTime
        dropBefore = decodeTime
        seekEpoch += 1
        pendingReset = true
        buffering = true
        decodeDeadline = clamped
        sourceEnded = false
        previewPending = true
        lastMediaEnd = decodeTime
        if clamped >= duration { state = .ended }
        else if state == .ended { state = .paused }
        audioPTSOrigin = nil
        audioNode?.stop()
        lock.unlock()
        resetMetrics()
        currentTime = clamped
        timeAnchor = clamped
        hostAnchor = CACurrentMediaTime()
        if transport != .stopped {
            startClock()
            startDecodeLoop()
        }
        publishTime(playing: isPlaying)
    }

    func shutdown() {
        metrics.setPlaying(false)
        endActivity()
        transport = .stopped
        decodeRunning = false
        lock.lock()
        videoFrames.removeAll()
        pendingSeek = nil
        comparisonFrame = nil
        dropBefore = 0
        seekEpoch += 1
        lock.unlock()
        decodeQueue.sync { self.source = nil }
        onMain {
            self.displayLink?.invalidate()
            self.displayLink = nil
            self.displayTarget = nil
            self.audioNode?.stop()
            self.audioEngine?.stop()
            self.audioEngine = nil
            self.audioNode = nil
            self.audioFormat = nil
        }
        lock.lock()
        videoFrames.removeAll()
        pendingSeek = nil
        dropBefore = 0
        audioPTSOrigin = nil
        sourceEnded = false
        previewPending = false
        lastMediaEnd = 0
        lock.unlock()
        currentTime = 0
        duration = 0
    }

    private func startClock() {
        onMain {
            if self.displayLink != nil { return }
            self.lastUIPublish = 0
            let target = DisplayTickTarget(session: self)
            guard let screen = NSScreen.main else { return }
            let link = screen.displayLink(target: target, selector: #selector(DisplayTickTarget.tick))
            link.add(to: .main, forMode: .common)
            self.displayTarget = target
            self.displayLink = link
        }
    }

    func displayTick() {
        guard transport != .stopped else { return }
        let playing = isPlaying
        let now = playing ? mediaTime() : currentTime
        currentTime = now
        lock.lock()
        decodeDeadline = now
        let frame: VideoFrame?
        var dropped: [VideoFrame] = []
        if previewPending, pendingSeek == nil, presenter.isReady, !videoFrames.isEmpty {
            frame = videoFrames.removeFirst()
        } else if playing {
            frame = VideoDisplay.take(
                now: now, frames: &videoFrames, ready: presenter.isReady,
                late: Timing.lateFrame, early: min(Timing.earlyFrame, 0.008), onDrop: { dropped.append($0) }
            )
        } else {
            frame = nil
        }
        metrics.queued(epoch: seekEpoch, count: videoFrames.count)
        lock.unlock()
        metrics.dropped(dropped)
        if let frame {
            let drawn = presenter.draw(frame.pixelBuffer) { [weak self] time, gpu, error in
                guard let self else { return }
                if let error {
                    self.fail(EnhancementFailure(stage: .presentation, message: error.localizedDescription), epoch: frame.trace.epoch)
                } else {
                    self.metrics.displayed(frame, at: time, gpuSeconds: gpu)

                }
            }
            if drawn {
                metrics.submitted(frame)
                lock.withLock {
                    if frame.trace.epoch == seekEpoch, !frame.trace.interpolated {
                        comparisonFrame = VideoFrame(pixelBuffer: frame.originalBuffer ?? frame.pixelBuffer, pts: frame.pts, duration: frame.duration, trace: frame.trace)
                    }
                }
            }
            lock.withLock {
                if drawn { previewPending = false }
                else { videoFrames.insert(frame, at: 0) }
            }
        }
        let finished = lock.withLock {
            sourceEnded && videoFrames.isEmpty && now >= min(lastMediaEnd, duration > 0 ? duration : lastMediaEnd)
        }
        if playing, finished {
            transport = .ended
            endActivity()
            metrics.setPlaying(false)
            audioNode?.stop()
            currentTime = duration > 0 ? duration : now
            publishTime(playing: false)
            return
        }
        let host = CACurrentMediaTime()
        if host - lastUIPublish >= Timing.uiInterval {
            lastUIPublish = host
            publishTime(playing: isPlaying)
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
        var catchingUp = false
        while decodeRunning, let source {
            lock.lock()
            let seekTo = pendingSeek
            pendingSeek = nil
            let epoch = seekEpoch
            let target = dropBefore
            let deadline = buffering || state != .playing ? target : decodeDeadline
            let shouldDecode = seekTo != nil || (!sourceEnded && videoFrames.count <= Timing.videoBacklog
                && (state == .playing || (previewPending && videoFrames.isEmpty)))
            lock.unlock()
            guard shouldDecode else {
                Thread.sleep(forTimeInterval: Timing.decodeIdle)
                continue
            }
            do {
                // This GCD task lives for the entire playback session. Drain Objective-C
                // conversion/model temporaries per pull; queued frames remain strongly owned.
                try autoreleasepool {
                    configureEnhancements()
                    if let seekTo {
                        catchingUp = false
                        try source.seek(to: seekTo)
                        enhanceLock.withLock { interpolation.reset() }
                    }
                    switch try source.pull() {
                    case .eof:
                        lock.withLock {
                            if epoch == seekEpoch { sourceEnded = true }
                        }
                    case .video(let frame):
                        if frame.pts + Timing.seekSlop >= target {
                            var input = frame
                            input.trace.epoch = epoch
                            metrics.sourceFrame(input)
                            if frame.pts < deadline - Timing.lateFrame || (catchingUp && frame.pts < deadline) {
                                metrics.droppedSource(epoch: epoch)
                                if !catchingUp { enhanceLock.withLock { interpolation.reset() } }
                                catchingUp = true
                                return
                            }
                            catchingUp = false
                            let outgoing = try enhance(input)
                            publishEnhanced(outgoing, epoch: epoch)
                        }
                    case .audio(let packet):
                        scheduleAudio(packet, epoch: epoch, target: target)
                    }
                }
            } catch {
                fail(error, epoch: epoch)
            }
        }
    }

    private func refreshUpscaler() {
        pipeline.upscaler = anime4KEnabled ? anime4K : passthrough
    }

    private func configureEnhancements() {
        let configuration = lock.withLock { () -> (EnhancementSettings, Bool, Bool) in
            defer { pendingEnhancements = false; pendingReset = false }
            return (requestedSettings, pendingEnhancements, pendingReset)
        }
        enhanceLock.withLock {
            if configuration.1 {
                anime4KEnabled = configuration.0.anime4KEnabled
                anime4K.resetFailure()
                interpolation.setRequested(configuration.0.interpolation)
                interpolation.restoreRequested()
                refreshUpscaler()
            } else if configuration.2 { interpolation.reset() }
        }
    }

    func enhance(_ frame: VideoFrame) throws -> [VideoFrame] {
        configureEnhancements()
        enhanceLock.lock()
        defer { enhanceLock.unlock() }
        let interval = PipelineMetrics.enhance.beginInterval("enhance")
        defer { PipelineMetrics.enhance.endInterval("enhance", interval) }
        let start = CACurrentMediaTime()
        let interpolated: [VideoFrame]
        do {
            interpolated = try interpolation.process(frame).map { output in
                var value = output
                value.originalBuffer = frame.pixelBuffer
                value.trace = frame.trace
                value.trace.interpolated = output.pts < frame.pts
                value.trace.interpolation = value.trace.interpolated ? interpolation.active : .off
                return value
            }
        } catch {
            throw EnhancementFailure(stage: .interpolation, message: error.localizedDescription)
        }
        let afterInterpolation = CACurrentMediaTime()
        let outgoing: [VideoFrame]
        do {
            outgoing = try interpolated.flatMap { try pipeline.upscaler.process($0) }
        } catch {
            throw EnhancementFailure(stage: .anime4K, message: error.localizedDescription)
        }
        var times = ["interpolation": afterInterpolation - start,
                     "anime4K": CACurrentMediaTime() - afterInterpolation,
                     "total": CACurrentMediaTime() - start]
        if let processor = interpolation.interpolator as? IFRNetProcessor {
            times.merge(processor.lastTimings) { _, new in new }
        } else if let processor = interpolation.interpolator as? VTInterpolationProcessor {
            times.merge(processor.lastTimings) { _, new in new }
        }
        metrics.processed(outgoing, input: frame, times: times)
        return outgoing
    }

    private static func defaultInterpolator(_ mode: InterpolationMode) -> FrameProcessor {
        switch mode {
        case .off:
            return PassthroughProcessor()
        case .fast:
            return VTInterpolationProcessor()
        case .quality:
            return IFRNetProcessor()
        }
    }

    private func fail(_ error: Error, epoch: Int) {
        lock.withLock {
            if epoch == seekEpoch {
                sourceEnded = true
                previewPending = false
                videoFrames.removeAll()
            }
        }
        if let failure = error as? EnhancementFailure { metrics.fail(failure, epoch: epoch) }
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ epoch == self.seekEpoch }) else { return }
            self.pause()
            if let failure = error as? EnhancementFailure { self.onEnhancementFailure?(failure) }
            else { self.onError?(message) }
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

    private func scheduleAudio(_ packet: AudioBuffer, epoch: Int, target: Double) {
        let skip = packet.framesToSkip(before: target)
        let count = packet.frameCount - skip
        guard let format = audioFormat, let node = audioNode, count > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            channels[0][i] = packet.pcm[(i + skip) * 2]
            channels[1][i] = packet.pcm[(i + skip) * 2 + 1]
        }
        lock.lock()
        guard epoch == seekEpoch else { lock.unlock(); return }
        let first = audioPTSOrigin == nil
        if first { audioPTSOrigin = packet.pts + Double(skip) / packet.sampleRate }
        lastMediaEnd = max(lastMediaEnd, packet.pts + Double(packet.frameCount) / packet.sampleRate)
        node.scheduleBuffer(buffer)
        lock.unlock()
        if first {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPlaying,
                      self.lock.withLock({ epoch == self.seekEpoch && !self.buffering }) else { return }
                self.audioNode?.play()
            }
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private func mediaTime() -> Double {
        if lock.withLock({ buffering }) { return currentTime }
        lock.lock()
        let origin = audioPTSOrigin
        lock.unlock()
        if hasAudio, transport == .playing, let origin, let node = audioNode,
           let nodeTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: nodeTime),
           playerTime.sampleRate > 0 {
            return MediaClock.fromAudio(
                origin: origin,
                sampleOrigin: 0,
                sampleTime: playerTime.sampleTime,
                sampleRate: playerTime.sampleRate,
                duration: duration
            )
        }
        return MediaClock.now(
            paused: transport != .playing,
            frozen: currentTime,
            anchor: timeAnchor,
            elapsed: CACurrentMediaTime() - hostAnchor,
            duration: duration
        )
    }
}

private final class DisplayTickTarget: NSObject {
    weak var session: PlaybackSession?

    init(session: PlaybackSession) {
        self.session = session
    }

    @objc func tick() {
        session?.displayTick()
    }
}

enum VideoDisplay {
    static func take(
        now: Double,
        frames: inout [VideoFrame],
        ready: Bool,
        late: Double,
        early: Double,
        onDrop: (VideoFrame) -> Void = { _ in }
    ) -> VideoFrame? {
        guard ready else { return nil }
        while let first = frames.first, first.pts < now - late {
            onDrop(frames.removeFirst())
        }
        if let first = frames.first, first.pts <= now + early {
            return frames.removeFirst()
        }
        return nil
    }
}
