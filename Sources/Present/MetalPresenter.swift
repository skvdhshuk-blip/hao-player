import CoreImage
import CoreVideo
import Foundation
import Metal
import QuartzCore

final class MetalPresenter {
    let metalLayer = CAMetalLayer()

    private let device: MTLDevice
    private let ciContext: CIContext

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Metal is required")
        }
        self.device = device
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsGravity = .resizeAspect
        ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
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
        let drawableSize = metalLayer.drawableSize
        guard isReady else { return false }
        guard let drawable = metalLayer.nextDrawable() else { return false }
        let image = CIImage(cvPixelBuffer: buffer)
        let src = image.extent
        guard src.width > 0, src.height > 0 else { return false }
        let scale = min(drawableSize.width / src.width, drawableSize.height / src.height)
        let scaledW = src.width * scale
        let scaledH = src.height * scale
        let x = (drawableSize.width - scaledW) / 2 - src.minX * scale
        let y = (drawableSize.height - scaledH) / 2 - src.minY * scale
        let placed = image.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
        let bounds = CGRect(origin: .zero, size: drawableSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(
            CIImage.black.cropped(to: bounds),
            to: drawable.texture,
            commandBuffer: nil,
            bounds: bounds,
            colorSpace: colorSpace
        )
        ciContext.render(
            placed,
            to: drawable.texture,
            commandBuffer: nil,
            bounds: bounds,
            colorSpace: colorSpace
        )
        drawable.present()
        return true
    }
}
