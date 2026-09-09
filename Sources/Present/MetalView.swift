import SwiftUI

struct MetalView: NSViewRepresentable {
    let presenter: MetalPresenter

    func makeNSView(context: Context) -> MetalCanvas {
        MetalCanvas(presenter: presenter)
    }

    func updateNSView(_ nsView: MetalCanvas, context: Context) {
        nsView.presenter = presenter
    }
}

final class MetalCanvas: NSView {
    var presenter: MetalPresenter

    init(presenter: MetalPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        wantsLayer = true
        layer = presenter.metalLayer
        presenter.metalLayer.backgroundColor = CGColor.black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        syncDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawable()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawable()
    }

    private func syncDrawable() {
        presenter.resize(to: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }
}
