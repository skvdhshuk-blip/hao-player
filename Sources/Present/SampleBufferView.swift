import AVFoundation
import SwiftUI

struct SampleBufferView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> SampleBufferNSView {
        let view = SampleBufferNSView()
        view.attach(layer)
        return view
    }

    func updateNSView(_ nsView: SampleBufferNSView, context: Context) {
        nsView.attach(layer)
    }
}

final class SampleBufferNSView: NSView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        if self.displayLayer === displayLayer {
            return
        }
        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        displayLayer.frame = bounds
    }

    override func layout() {
        super.layout()
        displayLayer?.frame = bounds
    }
}
