protocol FrameProcessor: AnyObject {
    func process(_ frame: VideoFrame) throws -> [VideoFrame]
    func reset()
}

extension FrameProcessor {
    func reset() {}
}

enum InterpolationError: Error {
    case unavailable
}
