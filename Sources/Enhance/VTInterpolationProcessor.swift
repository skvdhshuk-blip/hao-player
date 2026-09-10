import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

final class VTInterpolationProcessor: FrameProcessor {
    private(set) var lastTimings: [String: Double] = [:]
    private let processor = VTFrameProcessor()
    private let context = CIContext(mtlDevice: GPUContext.shared.device, options: [.workingColorSpace: NSNull()])
    private var previous: VTFrameProcessorFrame?
    private var sourcePool: CVPixelBufferPool?
    private var destinationPool: CVPixelBufferPool?
    private var width = 0
    private var height = 0
    private var started = false
    private var sequential = false
    private var sourceFormat: OSType = 0

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        lastTimings = [:]
        try ensureSession(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let conversionStart = CACurrentMediaTime()
        let input: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == sourceFormat, CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil {
            input = frame.pixelBuffer
        } else {
            input = try allocate(sourcePool)
            context.render(CIImage(cvPixelBuffer: frame.pixelBuffer), to: input,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        guard let current = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: CMTime(seconds: frame.pts, preferredTimescale: 60000)) else {
            throw InterpolationError.unavailable
        }
        lastTimings["inputConversion"] = CACurrentMediaTime() - conversionStart
        guard let previous else { self.previous = current; return [frame] }
        let processingStart = CACurrentMediaTime()
        let midPTS = (previous.presentationTimeStamp.seconds + frame.pts) / 2
        let output = try allocate(destinationPool)
        guard let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: CMTime(seconds: midPTS, preferredTimescale: 60000)),
              let parameters = VTFrameRateConversionParameters(sourceFrame: previous, nextFrame: current, opticalFlow: nil,
                  interpolationPhase: [0.5], submissionMode: sequential ? .sequential : .random, destinationFrames: [destination]) else {
            throw InterpolationError.unavailable
        }
        let completion = Completion()
        processor.process(parameters: parameters) { _, error in completion.finish(error) }
        try completion.wait()
        lastTimings["vtProcessing"] = CACurrentMediaTime() - processingStart
        self.previous = current
        sequential = true
        return [VideoFrame(pixelBuffer: output, pts: midPTS, duration: frame.duration / 2), frame]
    }

    func reset() { previous = nil; sequential = false }

    deinit { if started { processor.endSession() } }

    private func ensureSession(width: Int, height: Int) throws {
        if started, self.width == width, self.height == height { return }
        if started { processor.endSession(); started = false }
        previous = nil
        guard VTFrameRateConversionConfiguration.isSupported,
              let config = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height, usePrecomputedFlow: false, qualityPrioritization: .normal, revision: VTFrameRateConversionConfiguration.defaultRevision) else {
            throw EnhancementFailure(stage: .interpolation, message: "系统不支持当前视频的快档插帧")
        }
        // Allocate the pixel format and layout required by the system processor.
        sourceFormat = (config.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? 0
        sourcePool = try pool(config.sourcePixelBufferAttributes)
        destinationPool = try pool(config.destinationPixelBufferAttributes)
        try processor.startSession(configuration: config)
        started = true
        self.width = width
        self.height = height
    }

    private func pool(_ attributes: [String: any Sendable]) throws -> CVPixelBufferPool {
        var result: CVPixelBufferPool?
        var attrs = attributes
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &result) == kCVReturnSuccess,
              let result else { throw InterpolationError.unavailable }
        return result
    }

    private func allocate(_ pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw InterpolationError.unavailable }
        return buffer
    }

    private final class Completion: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var error: Error?
        func finish(_ error: Error?) { self.error = error; semaphore.signal() }
        func wait() throws { semaphore.wait(); if let error { throw error } }
    }
}
