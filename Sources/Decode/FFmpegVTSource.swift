import CoreVideo
import Foundation

final class FFmpegVTSource: VideoSource {
    private var reader: UnsafeMutableRawPointer?

    private(set) var duration = 0.0
    private(set) var hasAudio = false
    private(set) var sampleRate = 48000.0

    deinit {
        closeReader()
    }

    func open(_ url: URL) async throws {
        closeReader()
        var opened: UnsafeMutableRawPointer?
        let code = url.path.withCString { HaoReaderOpen(&opened, $0) }
        guard code == 0, let opened else {
            throw SourceError.decodeFailed(String(cString: HaoReaderLastError(nil)))
        }
        reader = opened
        duration = HaoReaderDuration(opened)
        hasAudio = HaoReaderHasAudio(opened) != 0
        let rate = HaoReaderAudioRate(opened)
        sampleRate = rate > 0 ? Double(rate) : 48000
    }

    func seek(to time: Double) throws {
        guard let reader else { throw SourceError.notOpen }
        if HaoReaderSeek(reader, time) < 0 {
            throw SourceError.decodeFailed(String(cString: HaoReaderLastError(reader)))
        }
    }

    func pull() throws -> MediaSample {
        guard let reader else { throw SourceError.notOpen }
        var kind: Int32 = 0
        var video = HaoVideoFrame()
        var audio = HaoAudioFrame()
        let err = HaoReaderRead(reader, &kind, &video, &audio)
        if err < 0 {
            throw SourceError.decodeFailed(String(cString: HaoReaderLastError(reader)))
        }
        switch kind {
        case Int32(HAO_EOF):
            return .eof
        case Int32(HAO_VIDEO):
            guard let raw = video.pixelBuffer else {
                throw SourceError.decodeFailed("empty video buffer")
            }
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeRetainedValue()
            return .video(VideoFrame(pixelBuffer: buffer, pts: video.pts, duration: video.duration))
        case Int32(HAO_AUDIO):
            guard let pcm = audio.pcm, audio.frameCount > 0 else {
                throw SourceError.decodeFailed("empty audio buffer")
            }
            return .audio(
                AudioBuffer(
                    pcm: pcm,
                    frameCount: Int(audio.frameCount),
                    sampleRate: Double(audio.sampleRate > 0 ? audio.sampleRate : Int32(sampleRate)),
                    pts: audio.pts
                )
            )
        default:
            throw SourceError.decodeFailed("unknown sample kind")
        }
    }

    private func closeReader() {
        if let reader {
            HaoReaderClose(reader)
            self.reader = nil
        }
    }
}
