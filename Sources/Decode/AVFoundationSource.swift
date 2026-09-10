import AVFoundation
import CoreVideo

final class AVFoundationSource: VideoSource {
    nonisolated static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private var asset: AVURLAsset?
    private var reader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var peekedVideo: VideoFrame?
    private var peekedAudio: AudioBuffer?
    private var nominalInterval = 1.0 / 24.0

    private(set) var duration = 0.0
    private(set) var hasAudio = false
    private(set) var sampleRate = 48000.0

    func open(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw SourceError.notPlayable }
        let length = try await asset.load(.duration)
        duration = length.seconds.isFinite ? length.seconds : 0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let rate = try await track.load(.nominalFrameRate)
            if rate > 0 { nominalInterval = 1 / Double(rate) }
        }
        _ = try await asset.loadTracks(withMediaType: .audio)
        self.asset = asset
        try startReader(from: 0)
    }

    func seek(to time: Double) throws {
        try startReader(from: time)
    }

    func pull() throws -> MediaSample {
        if peekedVideo == nil {
            peekedVideo = try copyVideo()
        }
        if peekedAudio == nil {
            peekedAudio = try copyAudio()
        }
        switch (peekedVideo, peekedAudio) {
        case (nil, nil):
            return .eof
        case (let video?, nil):
            peekedVideo = nil
            return .video(video)
        case (nil, let audio?):
            peekedAudio = nil
            return .audio(audio)
        case (let video?, let audio?):
            if video.pts <= audio.pts {
                peekedVideo = nil
                return .video(video)
            }
            peekedAudio = nil
            return .audio(audio)
        }
    }

    private func startReader(from time: Double) throws {
        guard let asset else { throw SourceError.notOpen }
        reader?.cancelReading()
        peekedVideo = nil
        peekedAudio = nil
        videoOutput = nil
        audioOutput = nil

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)

        if let video = asset.tracks(withMediaType: .video).first {
            let output = AVAssetReaderTrackOutput(
                track: video,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                videoOutput = output
            }
        }

        if let audio = asset.tracks(withMediaType: .audio).first {
            for desc in audio.formatDescriptions {
                let format = desc as! CMAudioFormatDescription
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format), asbd.pointee.mSampleRate > 0 {
                    sampleRate = asbd.pointee.mSampleRate
                    break
                }
            }
            if sampleRate <= 0 {
                sampleRate = 48000
            }
            let output = AVAssetReaderTrackOutput(
                track: audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: sampleRate,
                ]
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
                hasAudio = true
            }
        } else {
            hasAudio = false
        }

        guard reader.startReading() else {
            throw SourceError.decodeFailed(reader.error?.localizedDescription ?? "")
        }
        self.reader = reader
    }

    private func copyVideo() throws -> VideoFrame? {
        guard let output = videoOutput else { return nil }
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let dur = CMSampleBufferGetDuration(sample)
        let seconds = dur.isValid && dur.seconds > 0 ? dur.seconds : nominalInterval
        return VideoFrame(pixelBuffer: buffer, pts: pts, duration: seconds)
    }

    private func copyAudio() throws -> AudioBuffer? {
        guard let output = audioOutput else { return nil }
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let byteCount = CMBlockBufferGetDataLength(block)
        let floatCount = byteCount / MemoryLayout<Float>.size
        guard floatCount >= 2 else { return nil }
        let frames = floatCount / 2
        guard let raw = malloc(frames * 2 * MemoryLayout<Float>.size) else { return nil }
        let pcm = raw.assumingMemoryBound(to: Float.self)
        var status = noErr
        status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 2 * MemoryLayout<Float>.size, destination: raw)
        if status != noErr {
            free(raw)
            throw SourceError.decodeFailed("audio copy \(status)")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        return AudioBuffer(pcm: pcm, frameCount: frames, sampleRate: sampleRate, pts: pts)
    }
}
