import CoreImage
import CoreVideo
import Foundation
import Metal

enum PixelBufferIO {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var context: CIContext?

    static func bgra(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        try convert(source, forceCopy: false)
    }

    static func isolatedBGRA(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        try convert(source, forceCopy: true)
    }

    private static func convert(_ source: CVPixelBuffer, forceCopy: Bool) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        if !forceCopy, format == kCVPixelFormatType_32BGRA, CVPixelBufferGetIOSurface(source) != nil {
            return source
        }
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
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw InterpolationError.unavailable
        }
        let ci = contextLocked()
        let image = CIImage(cvPixelBuffer: source)
        ci.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    private static func contextLocked() -> CIContext {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            return context
        }
        let created: CIContext
        if let device = MTLCreateSystemDefaultDevice() {
            created = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
        } else {
            created = CIContext(options: [.workingColorSpace: NSNull()])
        }
        context = created
        return created
    }
}
