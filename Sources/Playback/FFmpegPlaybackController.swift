import AVFoundation
import CoreVideo
import QuartzCore

final class FFmpegPlaybackController: @unchecked Sendable {
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
    }

    let displayLayer = AVSampleBufferDisplayLayer()

    private var reader: UnsafeMutableRawPointer?
    private let decodeQueue = DispatchQueue(label: "hao.ffmpeg.decode")
    private let lock = NSLock()
    private var videoFrames: [(buffer: CVPixelBuffer, pts: Double, duration: Double)] = []
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

    private(set) var duration = 0.0
    private(set) var currentTime = 0.0
    var onTick: ((Double, Bool) -> Void)?

    var isPlaying: Bool { transport == .playing }

    func open(_ url: URL) throws {
        shutdown()
        var opened: UnsafeMutableRawPointer?
        let code = url.path.withCString { HaoReaderOpen(&opened, $0) }
        guard code == 0, let opened else {
            let detail = String(cString: HaoReaderLastError(nil))
            throw SourceError.decodeFailed(detail)
        }
        reader = opened
        duration = HaoReaderDuration(opened)
        hasAudio = HaoReaderHasAudio(opened) != 0
        let rate = HaoReaderAudioRate(opened)
        sampleRate = rate > 0 ? Double(rate) : 48000
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
        lock.unlock()
        currentTime = clamped
        timeAnchor = clamped
        hostAnchor = CACurrentMediaTime()
        onMain {
            self.displayLayer.flush()
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
        onMain {
            self.clockTimer?.invalidate()
            self.clockTimer = nil
            self.displayLayer.flushAndRemoveImage()
            self.audioNode?.stop()
            self.audioEngine?.stop()
            self.audioEngine = nil
            self.audioNode = nil
            self.audioFormat = nil
        }
        let closed = DispatchSemaphore(value: 0)
        decodeQueue.async {
            self.lock.lock()
            self.videoFrames.removeAll()
            self.pendingSeek = nil
            self.lock.unlock()
            if let reader = self.reader {
                HaoReaderClose(reader)
                self.reader = nil
            }
            closed.signal()
        }
        closed.wait()
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
        while let first = videoFrames.first, first.pts < now - Timing.lateFrame {
            videoFrames.removeFirst()
        }
        let frame: (CVPixelBuffer, Double, Double)?
        if let first = videoFrames.first, first.pts <= now + Timing.earlyFrame {
            frame = videoFrames.removeFirst()
        } else {
            frame = nil
        }
        lock.unlock()
        if let frame {
            enqueue(frame.0, pts: frame.1, duration: frame.2)
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
        while decodeRunning, let reader {
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
                _ = HaoReaderSeek(reader, seekTo)
            }
            if transport != .playing {
                Thread.sleep(forTimeInterval: Timing.decodeIdle)
                continue
            }
            var kind: Int32 = 0
            var video = HaoVideoFrame()
            var audio = HaoAudioFrame()
            let err = HaoReaderRead(reader, &kind, &video, &audio)
            if err < 0 {
                decodeRunning = false
                break
            }
            if kind == HAO_EOF {
                decodeRunning = false
                break
            }
            if kind == HAO_VIDEO, let raw = video.pixelBuffer {
                let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeRetainedValue()
                lock.lock()
                videoFrames.append((buffer, video.pts, video.duration))
                lock.unlock()
            } else if kind == HAO_AUDIO, let pcm = audio.pcm {
                scheduleAudio(pcm, frames: Int(audio.frameCount))
            }
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

    private func scheduleAudio(_ pcm: UnsafeMutablePointer<Float>, frames: Int) {
        defer { free(pcm) }
        guard let format = audioFormat, let node = audioNode, frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = channels[0]
        let right = channels[1]
        for i in 0..<frames {
            left[i] = pcm[i * 2]
            right[i] = pcm[i * 2 + 1]
        }
        node.scheduleBuffer(buffer)
    }

    private func enqueue(_ buffer: CVPixelBuffer, pts: Double, duration: Double) {
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: max(duration, 0.001), preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { return }
        displayLayer.enqueue(sample)
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
