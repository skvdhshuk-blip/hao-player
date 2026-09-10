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
        let out = try session.enhance(VideoFrame(pixelBuffer: buffer, pts: 0, duration: 0.04))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].pixelBuffer === buffer)
    }

    @MainActor
    func testFailurePausesAndManualDisableResumes() async throws {
        let session = PlaybackSession { mode -> FrameProcessor in
            if mode == .quality { return ThrowingInterpolator() }
            return PassthroughProcessor()
        }
        defer { session.shutdown() }
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false, interpolation: .quality))
        session.open(PreviewSource(buffer: try makeBuffer()))
        var failure: EnhancementFailure?
        session.onEnhancementFailure = { failure = $0 }
        session.play()
        for _ in 0..<100 where failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(failure)
        XCTAssertFalse(session.isPlaying)
        XCTAssertEqual(session.enhancementStatus.interpolationPhase, .failed)
        session.play()
        XCTAssertFalse(session.isPlaying)
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false, interpolation: .off))
        session.retryEnhancements()
        XCTAssertTrue(session.isPlaying)
        XCTAssertNil(session.enhancementStatus.failure)
    }

    @MainActor
    func testRetryRebuildsFailedProcessorAndPreservesPosition() async throws {
        var shouldFail = true
        var creations = 0
        let session = PlaybackSession { mode -> FrameProcessor in
            guard mode == .quality else { return PassthroughProcessor() }
            creations += 1
            return shouldFail ? ThrowingInterpolator() : FakeInterpolator()
        }
        defer { session.shutdown() }
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false, interpolation: .quality))
        session.open(PreviewSource(buffer: try makeBuffer()))
        session.seek(to: 4)
        session.play()
        for _ in 0..<100 where session.enhancementStatus.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<100 where session.isPlaying { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(session.enhancementStatus.failure)
        XCTAssertFalse(session.isPlaying)
        let failedCreations = creations
        let position = session.currentTime
        shouldFail = false
        session.retryEnhancements()
        for _ in 0..<100 where session.queuedFramePTS.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(creations, failedCreations)
        XCTAssertNil(session.enhancementStatus.failure)
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(session.dropBefore, position, accuracy: 0.01)
        XCTAssertEqual(session.metrics.snapshot().settings.interpolation, .quality)
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
        _ = try session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04))
        session.seek(to: 1)
        let out = try session.enhance(VideoFrame(pixelBuffer: try makeBuffer(), pts: 1, duration: 0.04))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].pts, 1, accuracy: 0.0001)
    }

    @MainActor
    func testPausedSeekDecodesTargetWithoutStartingPlayback() async throws {
        let session = PlaybackSession()
        defer { session.shutdown() }
        session.applyEnhancements(EnhancementSettings(anime4KEnabled: false))
        session.open(PreviewSource(buffer: try makeBuffer()))
        session.pause()
        session.seek(to: 5)
        for _ in 0..<50 where session.queuedFramePTS.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.queuedFramePTS, [5])
        XCTAssertEqual(session.currentTime, 5, accuracy: 0.001)
        XCTAssertFalse(session.isPlaying)
    }

    @MainActor
    func testEOFStopsAndPlayRestartsAtZero() async throws {
        let session = PlaybackSession()
        defer { session.shutdown() }
        session.open(StubSource(duration: 1))
        session.play()
        for _ in 0..<50 where session.isPlaying {
            try await Task.sleep(for: .milliseconds(10))
            session.displayTick()
        }
        XCTAssertFalse(session.isPlaying)
        XCTAssertEqual(session.currentTime, 1, accuracy: 0.001)
        session.play()
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(session.currentTime, 0, accuracy: 0.001)
    }

    func testSeekAudioDropsPrerollAndTrimsOverlappingPacket() {
        let count = 480
        let pcm = malloc(count * 2 * MemoryLayout<Float>.size)!.assumingMemoryBound(to: Float.self)
        let packet = AudioBuffer(pcm: pcm, frameCount: count, sampleRate: 48000, pts: 4)
        XCTAssertEqual(packet.framesToSkip(before: 3), 0)
        XCTAssertEqual(packet.framesToSkip(before: 5), 480)
        XCTAssertEqual(packet.framesToSkip(before: 4.005), 240)
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

private final class PreviewSource: VideoSource {
    let duration = 10.0
    let hasAudio = false
    let sampleRate = 48000.0
    private let buffer: CVPixelBuffer
    private var time = 0.0
    init(buffer: CVPixelBuffer) { self.buffer = buffer }
    func open(_ url: URL) async throws {}
    func seek(to time: Double) throws { self.time = time - 0.1 }
    func pull() throws -> MediaSample {
        defer { time += 0.1 }
        return .video(VideoFrame(pixelBuffer: buffer, pts: time, duration: 0.1))
    }
}
