import CoreVideo
import XCTest
@testable import HaoPlayer

final class PlaybackSessionTests: XCTestCase {
    func testOpenResetsDropBeforeAfterPreviousSeek() {
        let session = PlaybackSession()
        session.open(StubSource(duration: 120))
        session.seek(to: 88)
        XCTAssertEqual(session.dropBefore, 88, accuracy: 0.001)

        session.open(StubSource(duration: 10))
        XCTAssertEqual(session.dropBefore, 0, accuracy: 0.001)
    }

    func testEnhanceOffKeepsOneFrame() throws {
        let session = PlaybackSession()
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false, interpolation: .off))
        let buffer = try makeBuffer()
        let out = session.enhance(VideoFrame(pixelBuffer: buffer, pts: 0, duration: 0.04))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].pixelBuffer === buffer)
    }

    func testSlowQualityFailureStaysOnFast() throws {
        let session = PlaybackSession { mode in
            switch mode {
            case .quality:
                return SleepThenThrowInterpolator(seconds: 0.1)
            case .fast:
                return FakeInterpolator()
            case .off:
                return PassthroughProcessor()
            }
        }
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false, interpolation: .quality))
        _ = session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04))
        _ = session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0.04, duration: 0.04))
        XCTAssertEqual(session.activeInterpolation, .fast)
    }

    func testQualityFailureUsesFastBox() throws {
        let session = PlaybackSession { mode in
            switch mode {
            case .quality:
                return ThrowingInterpolator()
            case .fast:
                return FakeInterpolator()
            case .off:
                return PassthroughProcessor()
            }
        }
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false, interpolation: .quality))
        XCTAssertEqual(session.activeInterpolation, .quality)
        _ = session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04))
        let out = session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0.04, duration: 0.04))
        XCTAssertEqual(session.activeInterpolation, .fast)
        XCTAssertEqual(out.count, 1)
    }

    func testStaleEnhanceAfterBackwardSeekIsDiscarded() throws {
        let session = PlaybackSession()
        session.open(StubSource(duration: 120))
        let buffer = try makeBuffer()
        session.publishEnhanced(
            [VideoFrame(pixelBuffer: buffer, pts: 60, duration: 0.04)],
            epoch: session.seekEpoch
        )
        XCTAssertEqual(session.queuedFramePTS, [60])

        let epoch = session.seekEpoch
        session.seek(to: 10)
        session.publishEnhanced(
            [VideoFrame(pixelBuffer: buffer, pts: 60, duration: 0.04)],
            epoch: epoch
        )
        XCTAssertEqual(session.queuedFramePTS, [])
        XCTAssertNotEqual(session.seekEpoch, epoch)
    }

    func testSeekResetsInterpolator() throws {
        let session = PlaybackSession { mode in
            switch mode {
            case .fast:
                return FakeInterpolator()
            case .off, .quality:
                return PassthroughProcessor()
            }
        }
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false, interpolation: .fast))
        session.open(StubSource(duration: 10))
        _ = session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04))
        session.seek(to: 1)
        let out = session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 1, duration: 0.04))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].pts, 1, accuracy: 0.0001)
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HaoPlayerTests", code: 7)
        }
        return buffer
    }
}

private final class StubSource: VideoSource {
    let duration: Double
    let hasAudio = false
    let sampleRate = 48000.0

    init(duration: Double) {
        self.duration = duration
    }

    func open(_ url: URL) async throws {}
    func seek(to time: Double) throws {}
    func pull() throws -> MediaSample { .eof }
}
