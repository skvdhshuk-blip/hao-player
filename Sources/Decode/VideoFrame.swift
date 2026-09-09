import CoreMedia
import CoreVideo

struct VideoFrame {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime
    let duration: CMTime
}
