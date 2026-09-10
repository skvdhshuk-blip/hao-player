import CoreVideo
import XCTest
@testable import HaoPlayer

final class EnhancementMetricsTests: XCTestCase {
    func testOnlyPresentedFramesActivateAndOldCallbacksAreIgnored() throws {
        let metrics = EnhancementMetrics()
        let settings = EnhancementSettings(anime4KEnabled: true, interpolation: .quality)
        metrics.reset(epoch: 2, settings: settings)
        var frame = try frame(epoch: 2)
        frame.trace.anime4K = true
        frame.trace.interpolated = true
        frame.trace.interpolation = .quality
        metrics.processed([frame], input: frame, times: ["total": 0.01], now: 1)
        XCTAssertEqual(metrics.snapshot().status.anime4KPhase, .preparing)
        metrics.displayed(frame, at: 1)
        XCTAssertEqual(metrics.snapshot().status.anime4KPhase, .active)
        XCTAssertEqual(metrics.snapshot().status.interpolation, .quality)
        metrics.reset(epoch: 3, settings: settings)
        metrics.displayed(frame, at: 2)
        XCTAssertEqual(metrics.snapshot().status.interpolationPhase, .preparing)
    }

    func testOverloadReportsSlowWithoutChangingRequestedModeAndPauseFreezesCounts() throws {
        let metrics = EnhancementMetrics()
        let settings = EnhancementSettings(anime4KEnabled: true, interpolation: .quality)
        metrics.reset(epoch: 1, settings: settings)
        metrics.setPlaying(true, now: 1)
        var frame = try frame(epoch: 1)
        frame.trace.anime4K = true
        frame.trace.interpolated = true
        frame.trace.interpolation = .quality
        metrics.displayed(frame, at: 1)
        for i in 0..<20 {
            let time = 4 + Double(i) * 0.1
            metrics.processed([frame], input: frame, times: ["total": 0.1], now: time)
            metrics.displayed(frame, at: time)
        }
        metrics.setPlaying(false, now: 6)
        let before = metrics.snapshot(now: 6)
        XCTAssertTrue(before.status.performanceLimited)
        XCTAssertEqual(before.settings.interpolation, .quality)
        XCTAssertEqual(before.status.interpolation, .quality)
        metrics.displayed(frame, at: 20)
        let after = metrics.snapshot(now: 30)
        XCTAssertEqual(after.presented, before.presented)
        XCTAssertEqual(after.measuredSeconds, before.measuredSeconds)
    }

    func testZeroPresentationTimeNeverActivates() throws {
        let metrics = EnhancementMetrics()
        metrics.reset(epoch: 1, settings: EnhancementSettings())
        var value = try frame(epoch: 1)
        value.trace.anime4K = true
        metrics.displayed(value, at: 0)
        XCTAssertEqual(metrics.snapshot().status.anime4KPhase, .preparing)
        XCTAssertEqual(metrics.snapshot().presented, 0)
    }

    func testCleanupTimingIncludesOnlyCurrentPlayingSession() throws {
        let metrics = EnhancementMetrics()
        metrics.reset(epoch: 1, settings: EnhancementSettings())
        metrics.setPlaying(true, now: 1)
        metrics.displayed(try frame(epoch: 1), at: 1)
        metrics.completedCycle(epoch: 1, cleanup: 0.002, total: 0.045, now: 4)
        metrics.completedCycle(epoch: 0, cleanup: 1, total: 1, now: 5)
        metrics.setPlaying(false, now: 6)
        metrics.completedCycle(epoch: 1, cleanup: 1, total: 1, now: 7)
        let report = metrics.snapshot(now: 7)
        XCTAssertEqual(report.stages["temporaryCleanup"]?.count, 1)
        XCTAssertEqual(try XCTUnwrap(report.stages["temporaryCleanup"]).meanMS, 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.stages["processingWithCleanup"]).meanMS, 45, accuracy: 0.001)
    }

    private func frame(epoch: Int) throws -> VideoFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return VideoFrame(pixelBuffer: try XCTUnwrap(buffer), pts: 0, duration: 1 / 24, trace: FrameTrace(epoch: epoch))
    }
}
