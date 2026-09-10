import Foundation
import CoreMedia
import CoreVideo

struct FrameTrace: Sendable {
    var epoch = 0
    var interpolated = false
    var interpolation: InterpolationMode = .off
    var anime4K = false
    var queuedAt = 0.0
}

struct VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: Double
    let duration: Double
    var trace = FrameTrace()
    var originalBuffer: CVPixelBuffer?
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

    func framesToSkip(before time: Double) -> Int {
        guard sampleRate > 0, time > pts else { return 0 }
        return Int(min(Double(frameCount), ceil((time - pts) * sampleRate)))
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
