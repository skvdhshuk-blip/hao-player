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
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var textures: [String: MTLTexture] = [:]
    private var outputPool: CVPixelBufferPool?
    private var cachedWidth = 0
    private var cachedHeight = 0

    func forceFail() {
        failed = true
    }

    func resetFailure() {
        if failed {
            pipelines.removeAll()
            textures.removeAll()
            outputPool = nil
        }
        failed = false
    }

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        if failed {
            throw Anime4KError.encodeFailed
        }
        do {
            let buffer = try enhance(frame.pixelBuffer)
            var result = VideoFrame(pixelBuffer: buffer, pts: frame.pts, duration: frame.duration, trace: frame.trace, originalBuffer: frame.originalBuffer)
            result.trace.anime4K = true
            return [result]
        } catch {
            failed = true
            throw error
        }
    }

    private func enhance(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }
        try readyPipelines()
        let gpu = GPUContext.shared
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        guard width > 1, height > 1 else { throw Anime4KError.encodeFailed }
        if width != cachedWidth || height != cachedHeight {
            textures.removeAll()
            outputPool = nil
            cachedWidth = width
            cachedHeight = height
        }

        guard let command = gpu.queue.makeCommandBuffer() else { throw Anime4KError.encodeFailed }
        let source = try texture("SRC", width: width, height: height)
        var mapped: [MappedTexture] = []
        try upload(input, to: source, command: command, keep: &mapped)
        var slots: [String: MTLTexture] = ["MAIN": source]

        for pass in Self.passes {
            let destW = width * pass.scale
            let destH = height * pass.scale
            // Read/modify passes must not overwrite a texture they are sampling.
            // CNN scratch slots can be reused after the preceding encoder finishes.
            let key = pass.binds.contains(pass.save) ? pass.name : pass.save
            let dest = try texture("\(key)#\(destW)x\(destH)", width: destW, height: destH)
            guard let encoder = command.makeComputeCommandEncoder() else { throw Anime4KError.encodeFailed }
            guard let pipeline = pipelines[pass.name] else { throw Anime4KError.missingKernel(pass.name) }
            encoder.setComputePipelineState(pipeline)
            for (index, bind) in pass.binds.enumerated() {
                guard let tex = slots[bind] else { throw Anime4KError.encodeFailed }
                encoder.setTexture(tex, index: index)
            }
            encoder.setTexture(dest, index: pass.binds.count)
            dispatch(encoder, pipeline: pipeline, width: destW, height: destH)
            encoder.endEncoding()
            slots[pass.save] = dest
        }

        guard let final = slots["FINAL"] else { throw Anime4KError.outputFailed }
        let output = try nextOutput(width: width * 2, height: height * 2)
        guard let dest = gpu.map(output, plane: 0, format: .bgra8Unorm) else {
            throw Anime4KError.outputFailed
        }
        mapped.append(dest)
        guard let encoder = command.makeComputeCommandEncoder() else { throw Anime4KError.encodeFailed }
        encoder.setComputePipelineState(gpu.rgbaToBGRA)
        encoder.setTexture(final, index: 0)
        encoder.setTexture(dest.metal, index: 1)
        dispatch(encoder, pipeline: gpu.rgbaToBGRA, width: dest.metal.width, height: dest.metal.height)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        _ = mapped
        if let error = command.error {
            throw error
        }
        return output
    }

    private func upload(
        _ input: CVPixelBuffer,
        to dest: MTLTexture,
        command: MTLCommandBuffer,
        keep: inout [MappedTexture]
    ) throws {
        let gpu = GPUContext.shared
        let format = CVPixelBufferGetPixelFormatType(input)
        if format == kCVPixelFormatType_32BGRA {
            guard let src = gpu.map(input, plane: 0, format: .bgra8Unorm) else { throw Anime4KError.encodeFailed }
            keep.append(src)
            guard let encoder = command.makeComputeCommandEncoder() else { throw Anime4KError.encodeFailed }
            encoder.setComputePipelineState(gpu.bgraToRGBA)
            encoder.setTexture(src.metal, index: 0)
            encoder.setTexture(dest, index: 1)
            dispatch(encoder, pipeline: gpu.bgraToRGBA, width: dest.width, height: dest.height)
            encoder.endEncoding()
            return
        }
        if GPUContext.isBiplanar420(format) {
            guard let y = gpu.map(input, plane: 0, format: .r8Unorm),
                  let cbcr = gpu.map(input, plane: 1, format: .rg8Unorm) else {
                throw Anime4KError.encodeFailed
            }
            keep.append(y)
            keep.append(cbcr)
            var range: Float = GPUContext.isFullRange420(format) ? 1 : 0
            guard let encoder = command.makeComputeCommandEncoder() else { throw Anime4KError.encodeFailed }
            encoder.setComputePipelineState(gpu.ycbcrToRGBA)
            encoder.setTexture(y.metal, index: 0)
            encoder.setTexture(cbcr.metal, index: 1)
            encoder.setTexture(dest, index: 2)
            encoder.setBytes(&range, length: MemoryLayout<Float>.stride, index: 0)
            dispatch(encoder, pipeline: gpu.ycbcrToRGBA, width: dest.width, height: dest.height)
            encoder.endEncoding()
            return
        }
        let bgra = try PixelBufferIO.bgra(input)
        try upload(bgra, to: dest, command: command, keep: &keep)
    }

    private func readyPipelines() throws {
        if !pipelines.isEmpty { return }
        let gpu = GPUContext.shared
        var built: [String: MTLComputePipelineState] = [:]
        for pass in Self.passes {
            guard let fn = gpu.library.makeFunction(name: pass.name) else {
                throw Anime4KError.missingKernel(pass.name)
            }
            built[pass.name] = try gpu.device.makeComputePipelineState(function: fn)
        }
        pipelines = built
    }

    private func texture(_ key: String, width: Int, height: Int) throws -> MTLTexture {
        if let existing = textures[key], existing.width == width, existing.height == height {
            return existing
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let texture = GPUContext.shared.device.makeTexture(descriptor: desc) else {
            throw Anime4KError.encodeFailed
        }
        textures[key] = texture
        return texture
    }

    private func nextOutput(width: Int, height: Int) throws -> CVPixelBuffer {
        if outputPool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &outputPool) == kCVReturnSuccess else {
                throw Anime4KError.outputFailed
            }
        }
        var buffer: CVPixelBuffer?
        guard let outputPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &buffer) == kCVReturnSuccess,
              let buffer else { throw Anime4KError.outputFailed }
        return buffer
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(pipeline.maxTotalThreadsPerThreadgroup / w, 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
    }
}
