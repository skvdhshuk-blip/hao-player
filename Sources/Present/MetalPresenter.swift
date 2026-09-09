import CoreVideo
import Foundation
import Metal
import QuartzCore

private struct PresentUniforms {
    var drawableX: Float
    var drawableY: Float
    var _pad0: Float = 0
    var _pad1: Float = 0
    var destX: Float
    var destY: Float
    var destW: Float
    var destH: Float
}

final class MetalPresenter {
    let metalLayer = CAMetalLayer()

    private let gpu: GPUContext
    private let bgraPipeline: MTLRenderPipelineState
    private let ycbcrPipeline: MTLRenderPipelineState

    init() {
        let gpu = GPUContext.shared
        self.gpu = gpu
        metalLayer.device = gpu.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resize

        guard let vertex = gpu.library.makeFunction(name: "present_vertex"),
              let bgra = gpu.library.makeFunction(name: "present_fragment"),
              let ycbcr = gpu.library.makeFunction(name: "present_ycbcr_fragment") else {
            preconditionFailure("Present shaders missing")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.vertexFunction = vertex
        desc.fragmentFunction = bgra
        guard let bgraPipeline = try? gpu.device.makeRenderPipelineState(descriptor: desc) else {
            preconditionFailure("Present BGRA pipeline failed")
        }
        desc.fragmentFunction = ycbcr
        guard let ycbcrPipeline = try? gpu.device.makeRenderPipelineState(descriptor: desc) else {
            preconditionFailure("Present YCbCr pipeline failed")
        }
        self.bgraPipeline = bgraPipeline
        self.ycbcrPipeline = ycbcrPipeline
    }

    var isReady: Bool {
        metalLayer.drawableSize.width > 1 && metalLayer.drawableSize.height > 1
    }

    func resize(to size: CGSize, scale: CGFloat) {
        let width = size.width * scale
        let height = size.height * scale
        guard width > 1, height > 1 else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: width, height: height)
    }

    @discardableResult
    func draw(_ buffer: CVPixelBuffer) -> Bool {
        let interval = PipelineMetrics.present.beginInterval("present")
        defer { PipelineMetrics.present.endInterval("present", interval) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA {
            return drawBGRA(buffer)
        }
        if GPUContext.isBiplanar420(format) {
            return drawYCbCr(buffer, fullRange: GPUContext.isFullRange420(format))
        }
        guard let bgra = try? PixelBufferIO.bgra(buffer) else { return false }
        return drawBGRA(bgra)
    }

    private func drawBGRA(_ buffer: CVPixelBuffer) -> Bool {
        guard let mapped = gpu.map(buffer, plane: 0, format: .bgra8Unorm) else { return false }
        return encode(width: mapped.metal.width, height: mapped.metal.height, keep: [mapped]) { encoder, uniforms in
            encoder.setRenderPipelineState(bgraPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PresentUniforms>.stride, index: 0)
            encoder.setFragmentTexture(mapped.metal, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func drawYCbCr(_ buffer: CVPixelBuffer, fullRange: Bool) -> Bool {
        guard let y = gpu.map(buffer, plane: 0, format: .r8Unorm),
              let cbcr = gpu.map(buffer, plane: 1, format: .rg8Unorm) else {
            return false
        }
        var range: Float = fullRange ? 1 : 0
        return encode(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            keep: [y, cbcr]
        ) { encoder, uniforms in
            encoder.setRenderPipelineState(ycbcrPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PresentUniforms>.stride, index: 0)
            encoder.setFragmentTexture(y.metal, index: 0)
            encoder.setFragmentTexture(cbcr.metal, index: 1)
            encoder.setFragmentBytes(&range, length: MemoryLayout<Float>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func encode(
        width: Int,
        height: Int,
        keep: [MappedTexture],
        body: (MTLRenderCommandEncoder, inout PresentUniforms) -> Void
    ) -> Bool {
        let drawableSize = metalLayer.drawableSize
        guard isReady, width > 0, height > 0 else { return false }
        guard let drawable = metalLayer.nextDrawable() else { return false }
        guard let command = gpu.queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }

        let scale = min(drawableSize.width / Double(width), drawableSize.height / Double(height))
        let scaledW = Double(width) * scale
        let scaledH = Double(height) * scale
        var uniforms = PresentUniforms(
            drawableX: Float(drawableSize.width),
            drawableY: Float(drawableSize.height),
            destX: Float((drawableSize.width - scaledW) / 2),
            destY: Float((drawableSize.height - scaledH) / 2),
            destW: Float(scaledW),
            destH: Float(scaledH)
        )
        body(encoder, &uniforms)
        encoder.endEncoding()
        command.addCompletedHandler { _ in
            _ = keep
        }
        command.present(drawable)
        command.commit()
        return true
    }
}
