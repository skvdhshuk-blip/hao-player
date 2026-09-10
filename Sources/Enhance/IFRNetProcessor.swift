import CoreML
import CoreVideo
import CoreImage
import QuartzCore
import Foundation

final class IFRNetProcessor: FrameProcessor {
    private(set) var lastTimings: [String: Double] = [:]
    private let context = CIContext(mtlDevice: GPUContext.shared.device, options: [.workingColorSpace: NSNull()])
    private var previousImage: CVPixelBuffer?
    private var timestep: MLMultiArray?
    private var previous: VideoFrame?
    private var model: MLModel?
    private var loadFailed = false
    private var warmedWidth = 0
    private var warmedHeight = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var pools: [Int: CVPixelBufferPool] = [:]

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        guard width >= 2, height >= 2, width <= 1920, height <= 1088 else {
            throw EnhancementFailure(stage: .interpolation, message: "高质量档支持不超过 1920×1088 的源画面，当前为 \(width)×\(height)")
        }
        lastTimings = [:]
        try ready()
        guard let previous else {
            let start = CACurrentMediaTime()
            previousImage = try imageInput(frame.pixelBuffer)
            lastTimings["inputConversion"] = CACurrentMediaTime() - start
            self.previous = frame
            // Warm once per native size, not on every seek or dropped input frame.
            if warmedWidth != width || warmedHeight != height {
                _ = try runModel(previous: frame, current: frame)
                warmedWidth = width
                warmedHeight = height
            }
            return [frame]
        }
        let mid = try runModel(previous: previous, current: frame)
        self.previous = frame
        return [mid, frame]
    }

    func reset() {
        previous = nil
        previousImage = nil
    }

    private func ready() throws {
        if model != nil { return }
        if loadFailed { throw InterpolationError.unavailable }
        do {
            model = try Self.loadModel()
        } catch {
            loadFailed = true
            throw InterpolationError.unavailable
        }
    }

    private func runModel(previous: VideoFrame, current: VideoFrame) throws -> VideoFrame {
        guard let model else { throw InterpolationError.unavailable }
        let conversionStart = CACurrentMediaTime()
        guard let left = previousImage else { throw InterpolationError.unavailable }
        let right = try imageInput(current.pixelBuffer)
        let width = CVPixelBufferGetWidth(current.pixelBuffer)
        let height = CVPixelBufferGetHeight(current.pixelBuffer)
        if timestep == nil {
            timestep = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .float32)
            timestep?[0] = 0.5
        }
        guard let timestep else { throw InterpolationError.unavailable }
        lastTimings["inputConversion"] = CACurrentMediaTime() - conversionStart
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "img0": MLFeatureValue(pixelBuffer: left),
            "img1": MLFeatureValue(pixelBuffer: right),
            "timestep": MLFeatureValue(multiArray: timestep),
        ])
        let modelStart = CACurrentMediaTime()
        let out = try model.prediction(from: input)
        lastTimings["model"] = CACurrentMediaTime() - modelStart
        guard let pred = out.featureValue(for: "imgt")?.imageBufferValue else {
            throw InterpolationError.unavailable
        }
        let outputStart = CACurrentMediaTime()
        let buffer = try makeBuffer(width: width, height: height)
        // Padding is on the bottom/right in the model's top-left image coordinates.
        let padding = CVPixelBufferGetHeight(pred) - height
        let image = CIImage(cvPixelBuffer: pred).transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(padding)))
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        lastTimings["outputConversion"] = CACurrentMediaTime() - outputStart
        previousImage = right
        return VideoFrame(
            pixelBuffer: buffer,
            pts: (previous.pts + current.pts) / 2,
            duration: current.duration / 2
        )
    }

    private func imageInput(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let paddedW = ((width + 63) / 64) * 64, paddedH = ((height + 63) / 64) * 64
        let buffer = try makeBuffer(width: paddedW, height: paddedH)
        let bounds = CGRect(x: 0, y: 0, width: paddedW, height: paddedH)
        let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(paddedH - height)))
        let black = CIImage(color: .black).cropped(to: bounds)
        context.render(image.composited(over: black), to: buffer, bounds: bounds, colorSpace: colorSpace)
        return buffer
    }

    private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let key = width << 16 | height
        if pools[key] == nil {
            // Only the native and padded size are needed. Retained outputs remain
            // owned by the display queue even when an old size's pool is removed.
            if pools.count >= 2 { pools.removeAll() }
            var pool: CVPixelBufferPool?
            let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else { throw InterpolationError.unavailable }
            pools[key] = pool
        }
        var buffer: CVPixelBuffer?
        guard let pool = pools[key], CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw InterpolationError.unavailable }
        return buffer
    }

    private static func loadModel() throws -> MLModel {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "IFRNet_S", withExtension: "mlmodelc")
            ?? bundle.url(forResource: "IFRNet_S", withExtension: "mlpackage") else {
            throw InterpolationError.unavailable
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: configuration)
    }
}
