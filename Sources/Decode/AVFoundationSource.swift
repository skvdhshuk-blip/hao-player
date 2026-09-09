import AVFoundation

final class AVFoundationSource: VideoSource {
    nonisolated static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private(set) var duration: CMTime = .invalid
    private var asset: AVURLAsset?

    func open(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw SourceError.notPlayable }
        duration = try await asset.load(.duration)
        self.asset = asset
    }

    func makePlayerItem() throws -> AVPlayerItem {
        guard let asset else { throw SourceError.notOpen }
        return AVPlayerItem(asset: asset)
    }

    func seek(to time: CMTime) async throws {
        _ = time
    }

    func pullFrame() async throws -> VideoFrame {
        throw SourceError.framePullNotReady
    }
}
