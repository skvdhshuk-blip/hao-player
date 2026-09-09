import CoreMedia
import CoreVideo

struct VideoFrame {
    let pixelBuffer: CVPixelBuffer
    let pts: Double
    let duration: Double
}

final class AudioBuffer {
    let pcm: UnsafeMutablePointer<Float>
    let frameCount: Int
    let sampleRate: Double
    let pts: Double

    init(pcm: UnsafeMutablePointer<Float>, frameCount: Int, sampleRate: Double, pts: Double) {
        self.pcm = pcm
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.pts = pts
    }

    deinit {
        free(pcm)
    }
}

enum MediaSample {
    case video(VideoFrame)
    case audio(AudioBuffer)
    case eof
}
