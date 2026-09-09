import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// `VTFrameProcessor` over-releases submitted IOSurfaces on process failure
/// and during `endSession` / deinit. Sessions therefore live until process
/// exit, and a buffer handed to `process` can be marked stolen so we skip
/// `CFRelease`.
private enum VTSessionKeepalive {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [VTFrameProcessor] = []

    static func keep(_ processor: VTFrameProcessor) {
        lock.lock()
        sessions.append(processor)
        lock.unlock()
    }
}

private final class VTOwnedBuffer {
    private let ref: Unmanaged<CVPixelBuffer>
    let pts: TimeInterval
    let duration: TimeInterval
    private var stolen = false

    init(_ buffer: CVPixelBuffer, pts: TimeInterval, duration: TimeInterval) {
        ref = Unmanaged.passRetained(buffer)
        self.pts = pts
        self.duration = duration
    }

    deinit {
        if !stolen {
            ref.release()
        }
    }

    var pixelBuffer: CVPixelBuffer {
        ref.takeUnretainedValue()
    }

    func relinquishToVT() {
        stolen = true
    }
}

final class VTInterpolationProcessor: FrameProcessor {
    private var processor = VTFrameProcessor()
    private var previous: VTOwnedBuffer?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var started = false

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        let prepared = VTOwnedBuffer(
            try PixelBufferIO.isolatedBGRA(frame.pixelBuffer),
            pts: frame.pts,
            duration: frame.duration
        )
        try ensureSession(width: CVPixelBufferGetWidth(prepared.pixelBuffer),
                          height: CVPixelBufferGetHeight(prepared.pixelBuffer))
        guard let last = previous else {
            previous = prepared
            return [frame]
        }
        do {
            let mid = try interpolate(previous: last, current: prepared)
            previous = prepared
            return [mid, frame]
        } catch {
            last.relinquishToVT()
            prepared.relinquishToVT()
            previous = nil
            throw error
        }
    }

    func reset() {
        previous = nil
    }

    deinit {
        if started {
            VTSessionKeepalive.keep(processor)
        }
    }

    private func ensureSession(width: Int, height: Int) throws {
        if started, width == sessionWidth, height == sessionHeight {
            return
        }
        replaceSession()
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            throw InterpolationError.unavailable
        }
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width,
            frameHeight: height,
            numberOfInterpolatedFrames: 1
        ) else {
            throw InterpolationError.unavailable
        }
        try processor.startSession(configuration: configuration)
        sessionWidth = width
        sessionHeight = height
        started = true
        previous = nil
    }

    private func replaceSession() {
        previous = nil
        guard started else { return }
        started = false
        VTSessionKeepalive.keep(processor)
        processor = VTFrameProcessor()
    }

    private func interpolate(previous: VTOwnedBuffer, current: VTOwnedBuffer) throws -> VideoFrame {
        let source = try wrapped(current)
        let reference = try wrapped(previous)
        let midPTS = (previous.pts + current.pts) / 2
        let destination = VTOwnedBuffer(
            try makeDestination(like: current.pixelBuffer),
            pts: midPTS,
            duration: current.duration / 2
        )
        guard let destFrame = VTFrameProcessorFrame(
            buffer: destination.pixelBuffer,
            presentationTimeStamp: CMTime(seconds: midPTS, preferredTimescale: 600)
        ) else {
            throw InterpolationError.unavailable
        }
        guard let parameters = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: source,
            previousFrame: reference,
            interpolationPhase: [0.5],
            destinationFrames: [destFrame]
        ) else {
            throw InterpolationError.unavailable
        }

        let lock = NSLock()
        var processError: Error?
        let done = DispatchSemaphore(value: 0)
        processor.process(parameters: parameters) { _, error in
            lock.lock()
            processError = error
            lock.unlock()
            done.signal()
        }
        done.wait()
        lock.lock()
        let error = processError
        lock.unlock()
        if let error {
            destination.relinquishToVT()
            throw error
        }
        return VideoFrame(
            pixelBuffer: try PixelBufferIO.isolatedBGRA(destination.pixelBuffer),
            pts: midPTS,
            duration: current.duration / 2
        )
    }

    private func wrapped(_ frame: VTOwnedBuffer) throws -> VTFrameProcessorFrame {
        let time = CMTime(seconds: frame.pts, preferredTimescale: 600)
        guard let wrapped = VTFrameProcessorFrame(
            buffer: frame.pixelBuffer,
            presentationTimeStamp: time
        ) else {
            throw InterpolationError.unavailable
        }
        return wrapped
    }

    private func makeDestination(like source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            CVPixelBufferGetPixelFormatType(source),
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw InterpolationError.unavailable
        }
        return buffer
    }
}
