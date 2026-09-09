import CoreML
import CoreVideo
import Foundation

final class IFRNetProcessor: FrameProcessor {
    /// IFRNet-S cannot keep up at typical 720p source intervals; fail immediately
    /// so `InterpolationRuntime` can drop to the fast box.
    private static let realtimePixels = 640 * 400

    private var previous: VideoFrame?
    private var model: MLModel?
    private var loadFailed = false

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        let pixels = CVPixelBufferGetWidth(frame.pixelBuffer) * CVPixelBufferGetHeight(frame.pixelBuffer)
        if pixels > Self.realtimePixels {
            throw InterpolationError.unavailable
        }
        try ready()
        guard let previous else {
            self.previous = frame
            return [frame]
        }
        let mid = try runModel(previous: previous, current: frame)
        self.previous = frame
        return [mid, frame]
    }

    func reset() {
        previous = nil
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
        let left = try PixelBufferIO.bgra(previous.pixelBuffer)
        let right = try PixelBufferIO.bgra(current.pixelBuffer)
        let width = CVPixelBufferGetWidth(right)
        let height = CVPixelBufferGetHeight(right)
        let img0 = try IFRNetTensor.rgb(from: left)
        let img1 = try IFRNetTensor.rgb(from: right)
        let timestep = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .float32)
        timestep[0] = 0.5
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "img0": MLFeatureValue(multiArray: img0),
            "img1": MLFeatureValue(multiArray: img1),
            "timestep": MLFeatureValue(multiArray: timestep),
        ])
        let out = try model.prediction(from: input)
        guard let pred = out.featureValue(for: "imgt")?.multiArrayValue else {
            throw InterpolationError.unavailable
        }
        let buffer = try IFRNetTensor.pixelBuffer(from: pred, width: width, height: height)
        return VideoFrame(
            pixelBuffer: buffer,
            pts: (previous.pts + current.pts) / 2,
            duration: current.duration / 2
        )
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

enum IFRNetTensor {
    static func rgb(from buffer: CVPixelBuffer) throws -> MLMultiArray {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let paddedW = ((width + 63) / 64) * 64
        let paddedH = ((height + 63) / 64) * 64
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: paddedH), NSNumber(value: paddedW)], dataType: .float32)
        let floats = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        floats.assign(repeating: 0, count: array.count)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw InterpolationError.unavailable
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let plane = paddedW * paddedH
        for y in 0..<height {
            for x in 0..<width {
                let pixel = ptr + y * stride + x * 4
                let i = y * paddedW + x
                floats[i] = Float(pixel[2]) / 255
                floats[plane + i] = Float(pixel[1]) / 255
                floats[plane * 2 + i] = Float(pixel[0]) / 255
            }
        }
        return array
    }

    static func pixelBuffer(from array: MLMultiArray, width: Int, height: Int) throws -> CVPixelBuffer {
        guard array.shape.count == 4 else { throw InterpolationError.unavailable }
        let outH = array.shape[2].intValue
        let outW = array.shape[3].intValue
        guard width <= outW, height <= outH else { throw InterpolationError.unavailable }
        let strides = array.strides.map(\.intValue)
        guard strides.count == 4 else { throw InterpolationError.unavailable }

        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw InterpolationError.unavailable
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw InterpolationError.unavailable
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let r = clamp01(sample(array, channel: 0, y: y, x: x, strides: strides))
                let g = clamp01(sample(array, channel: 1, y: y, x: x, strides: strides))
                let b = clamp01(sample(array, channel: 2, y: y, x: x, strides: strides))
                let pixel = ptr + y * stride + x * 4
                pixel[0] = UInt8((b * 255).rounded())
                pixel[1] = UInt8((g * 255).rounded())
                pixel[2] = UInt8((r * 255).rounded())
                pixel[3] = 255
            }
        }
        return buffer
    }

    private static func sample(
        _ array: MLMultiArray,
        channel: Int,
        y: Int,
        x: Int,
        strides: [Int]
    ) -> Float {
        let index = channel * strides[1] + y * strides[2] + x * strides[3]
        switch array.dataType {
        case .float16:
            return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[index])
        case .float32:
            return array.dataPointer.assumingMemoryBound(to: Float.self)[index]
        default:
            return array[[0, channel, y, x] as [NSNumber]].floatValue
        }
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
