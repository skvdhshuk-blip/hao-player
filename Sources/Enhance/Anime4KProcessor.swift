import CoreImage
import CoreVideo
import Foundation
import Metal

enum Anime4KError: Error {
    case noMetal
    case missingKernel(String)
    case encodeFailed
    case outputFailed
}

final class Anime4KProcessor: FrameProcessor {
    private struct Pass {
        let name: String
        let binds: [String]
        let save: String
        let scale: Int
    }

    /// Clamp stats first; PREKERNEL clamp last (mpv Hook order).
    private static let passes: [Pass] = [
        Pass(name: "a4k_00_Anime4K_v4_0_De_Ring_Compute_Statistics", binds: ["MAIN"], save: "STATSMAX", scale: 1),
        Pass(name: "a4k_01_Anime4K_v4_0_De_Ring_Compute_Statistics", binds: ["MAIN", "STATSMAX"], save: "STATSMAX", scale: 1),
        Pass(name: "a4k_03_Anime4K_v4_0_Restore_CNN_M_Conv_4x3x3x3", binds: ["MAIN"], save: "conv2d_tf", scale: 1),
        Pass(name: "a4k_04_Anime4K_v4_0_Restore_CNN_M_Conv_4x3x3x8", binds: ["conv2d_tf"], save: "conv2d_1_tf", scale: 1),
        Pass(name: "a4k_05_Anime4K_v4_0_Restore_CNN_M_Conv_4x3x3x8", binds: ["conv2d_1_tf"], save: "conv2d_2_tf", scale: 1),
        Pass(name: "a4k_06_Anime4K_v4_0_Restore_CNN_M_Conv_4x3x3x8", binds: ["conv2d_2_tf"], save: "conv2d_3_tf", scale: 1),
        Pass(name: "a4k_07_Anime4K_v4_0_Restore_CNN_M_Conv_4x3x3x8", binds: ["conv2d_3_tf"], save: "conv2d_4_tf", scale: 1),
        Pass(name: "a4k_08_Anime4K_v4_0_Restore_CNN_M_Conv_4x3x3x8", binds: ["conv2d_4_tf"], save: "conv2d_5_tf", scale: 1),
        Pass(name: "a4k_09_Anime4K_v4_0_Restore_CNN_M_Conv_4x3x3x8", binds: ["conv2d_5_tf"], save: "conv2d_6_tf", scale: 1),
        Pass(name: "a4k_10_Anime4K_v4_0_Restore_CNN_M_Conv_3x1x1x56", binds: ["MAIN", "conv2d_tf", "conv2d_1_tf", "conv2d_2_tf", "conv2d_3_tf", "conv2d_4_tf", "conv2d_5_tf", "conv2d_6_tf"], save: "MAIN", scale: 1),
        Pass(name: "a4k_11_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x3x3x3", binds: ["MAIN"], save: "conv2d_tf", scale: 1),
        Pass(name: "a4k_12_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x3x3x8", binds: ["conv2d_tf"], save: "conv2d_1_tf", scale: 1),
        Pass(name: "a4k_13_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x3x3x8", binds: ["conv2d_1_tf"], save: "conv2d_2_tf", scale: 1),
        Pass(name: "a4k_14_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x3x3x8", binds: ["conv2d_2_tf"], save: "conv2d_3_tf", scale: 1),
        Pass(name: "a4k_15_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x3x3x8", binds: ["conv2d_3_tf"], save: "conv2d_4_tf", scale: 1),
        Pass(name: "a4k_16_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x3x3x8", binds: ["conv2d_4_tf"], save: "conv2d_5_tf", scale: 1),
        Pass(name: "a4k_17_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x3x3x8", binds: ["conv2d_5_tf"], save: "conv2d_6_tf", scale: 1),
        Pass(name: "a4k_18_Anime4K_v3_2_Upscale_CNN_x2_M_Conv_4x1x1x56", binds: ["conv2d_tf", "conv2d_1_tf", "conv2d_2_tf", "conv2d_3_tf", "conv2d_4_tf", "conv2d_5_tf", "conv2d_6_tf"], save: "conv2d_last_tf", scale: 1),
        Pass(name: "a4k_19_Anime4K_v3_2_Upscale_CNN_x2_M_Depth_to_Space", binds: ["MAIN", "conv2d_last_tf"], save: "MAIN", scale: 2),
        Pass(name: "a4k_02_Anime4K_v4_0_De_Ring_Clamp", binds: ["MAIN", "STATSMAX"], save: "FINAL", scale: 2),
    ]

    private let lock = NSLock()
    private var failed = false
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var ciContext: CIContext?
    private var textures: [String: MTLTexture] = [:]
    private var cachedWidth = 0
    private var cachedHeight = 0

    func forceFail() {
        failed = true
    }

    func resetFailure() {
        failed = false
    }

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        if failed {
            return [frame]
        }
        do {
            let buffer = try enhance(frame.pixelBuffer)
            return [VideoFrame(pixelBuffer: buffer, pts: frame.pts, duration: frame.duration)]
        } catch {
            failed = true
            throw error
        }
    }

    private func enhance(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }
        let gpu = try readyGPU()
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        guard width > 1, height > 1 else { throw Anime4KError.encodeFailed }
        if width != cachedWidth || height != cachedHeight {
            textures.removeAll()
            cachedWidth = width
            cachedHeight = height
        }

        let source = try texture("SRC", width: width, height: height)
        let image = CIImage(cvPixelBuffer: input)
        gpu.ci.render(
            image,
            to: source,
            commandBuffer: nil,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        var slots: [String: MTLTexture] = ["MAIN": source]

        guard let command = gpu.queue.makeCommandBuffer() else { throw Anime4KError.encodeFailed }
        for pass in Self.passes {
            let destW = width * pass.scale
            let destH = height * pass.scale
            let dest = try texture("\(pass.save)#\(destW)x\(destH)", width: destW, height: destH)
            guard let encoder = command.makeComputeCommandEncoder() else { throw Anime4KError.encodeFailed }
            guard let pipeline = pipelines[pass.name] else { throw Anime4KError.missingKernel(pass.name) }
            encoder.setComputePipelineState(pipeline)
            for (index, bind) in pass.binds.enumerated() {
                guard let tex = slots[bind] else { throw Anime4KError.encodeFailed }
                encoder.setTexture(tex, index: index)
            }
            encoder.setTexture(dest, index: pass.binds.count)
            let w = pipeline.threadExecutionWidth
            let h = max(pipeline.maxTotalThreadsPerThreadgroup / w, 1)
            encoder.dispatchThreads(
                MTLSize(width: destW, height: destH, depth: 1),
                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
            )
            encoder.endEncoding()
            slots[pass.save] = dest
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw error
        }
        guard let final = slots["FINAL"] else { throw Anime4KError.outputFailed }
        return try makePixelBuffer(from: final, ci: gpu.ci)
    }

    private struct GPU {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let ci: CIContext
    }

    private func readyGPU() throws -> GPU {
        if let device, let queue, let ciContext, !pipelines.isEmpty {
            return GPU(device: device, queue: queue, ci: ciContext)
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            throw Anime4KError.noMetal
        }
        var built: [String: MTLComputePipelineState] = [:]
        for pass in Self.passes {
            guard let fn = library.makeFunction(name: pass.name) else {
                throw Anime4KError.missingKernel(pass.name)
            }
            built[pass.name] = try device.makeComputePipelineState(function: fn)
        }
        let ci = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
        self.device = device
        self.queue = queue
        self.library = library
        self.pipelines = built
        self.ciContext = ci
        return GPU(device: device, queue: queue, ci: ci)
    }

    private func texture(_ key: String, width: Int, height: Int) throws -> MTLTexture {
        if let existing = textures[key], existing.width == width, existing.height == height {
            return existing
        }
        guard let device else { throw Anime4KError.noMetal }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw Anime4KError.encodeFailed }
        textures[key] = texture
        return texture
    }

    private func makePixelBuffer(from texture: MTLTexture, ci: CIContext) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            texture.width,
            texture.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { throw Anime4KError.outputFailed }
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            throw Anime4KError.outputFailed
        }
        ci.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }
}
