protocol FrameProcessor: AnyObject {
    func process(_ frame: VideoFrame) throws -> [VideoFrame]
}
