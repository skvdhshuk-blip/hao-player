import Foundation

/// The selected algorithm is never changed by performance or processing errors.
final class InterpolationRuntime {
    private let make: (InterpolationMode) -> FrameProcessor
    private var requested: InterpolationMode = .off
    private(set) var active: InterpolationMode = .off
    private(set) var interpolator: FrameProcessor

    init(make: @escaping (InterpolationMode) -> FrameProcessor) {
        self.make = make
        interpolator = make(.off)
    }

    func setRequested(_ mode: InterpolationMode) {
        guard mode != requested else { return }
        requested = mode
        restoreRequested()
    }

    func restoreRequested() {
        active = requested
        interpolator = make(requested)
    }

    func reset() { interpolator.reset() }

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        try interpolator.process(frame)
    }
}
