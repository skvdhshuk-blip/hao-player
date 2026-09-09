final class PassthroughProcessor: FrameProcessor {
    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        [frame]
    }
}
