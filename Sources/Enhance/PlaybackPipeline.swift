final class PlaybackPipeline {
    var interpolator: FrameProcessor
    var upscaler: FrameProcessor

    init(
        interpolator: FrameProcessor = PassthroughProcessor(),
        upscaler: FrameProcessor = PassthroughProcessor()
    ) {
        self.interpolator = interpolator
        self.upscaler = upscaler
    }

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        try interpolator.process(frame).flatMap { try upscaler.process($0) }
    }
}
