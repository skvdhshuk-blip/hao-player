import CoreVideo
import Metal

struct MappedTexture: @unchecked Sendable {
    let cv: CVMetalTexture
    let metal: MTLTexture
}

final class GPUContext: @unchecked Sendable {
    static let shared: GPUContext = {
        guard let context = GPUContext() else {
            preconditionFailure("Metal is required")
        }
        return context
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let ycbcrToRGBA: MTLComputePipelineState
    let bgraToRGBA: MTLComputePipelineState
    let rgbaToBGRA: MTLComputePipelineState

    private var textureCache: CVMetalTextureCache
    private let lock = NSLock()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            return nil
        }
        guard let ycbcr = library.makeFunction(name: "ycbcr_to_rgba16"),
              let bgra = library.makeFunction(name: "bgra_to_rgba16"),
              let rgba = library.makeFunction(name: "rgba16_to_bgra8"),
              let ycbcrToRGBA = try? device.makeComputePipelineState(function: ycbcr),
              let bgraToRGBA = try? device.makeComputePipelineState(function: bgra),
              let rgbaToBGRA = try? device.makeComputePipelineState(function: rgba) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
        self.textureCache = cache
        self.ycbcrToRGBA = ycbcrToRGBA
        self.bgraToRGBA = bgraToRGBA
        self.rgbaToBGRA = rgbaToBGRA
    }

    func map(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MappedTexture? {
        lock.lock()
        defer { lock.unlock() }
        let width = plane == 0
            ? CVPixelBufferGetWidth(buffer)
            : CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = plane == 0
            ? CVPixelBufferGetHeight(buffer)
            : CVPixelBufferGetHeightOfPlane(buffer, plane)
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            format,
            width,
            height,
            plane,
            &texture
        )
        guard status == kCVReturnSuccess, let texture, let metal = CVMetalTextureGetTexture(texture) else {
            return nil
        }
        return MappedTexture(cv: texture, metal: metal)
    }

    static func isBiplanar420(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func isFullRange420(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }
}
