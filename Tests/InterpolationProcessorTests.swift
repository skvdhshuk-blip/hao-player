import CoreML
import CoreVideo
import XCTest
@testable import HaoPlayer

final class InterpolationProcessorTests: XCTestCase {
    func testFailurePropagatesWithoutChangingSelection() throws {
        let runtime = InterpolationRuntime { mode -> FrameProcessor in
            if mode == .quality { return ThrowingInterpolator() }
            return PassthroughProcessor()
        }
        runtime.setRequested(.quality)
        _ = try runtime.process(VideoFrame(pixelBuffer: makeBuffer(), pts: 0, duration: 0.04))
        XCTAssertThrowsError(try runtime.process(VideoFrame(pixelBuffer: makeBuffer(), pts: 0.04, duration: 0.04)))
        XCTAssertEqual(runtime.active, .quality)
        runtime.restoreRequested()
        XCTAssertEqual(try runtime.process(VideoFrame(pixelBuffer: makeBuffer(), pts: 1, duration: 0.04)).count, 1)
        XCTAssertEqual(runtime.active, .quality)
    }

    func testResetDoesNotInterpolateAcrossSeek() throws {
        let runtime = InterpolationRuntime { _ in FakeInterpolator() }
        runtime.setRequested(.fast)
        _ = try runtime.process(VideoFrame(pixelBuffer: makeBuffer(), pts: 0, duration: 0.04))
        let out = try runtime.process(VideoFrame(pixelBuffer: makeBuffer(), pts: 0.04, duration: 0.04))
        XCTAssertEqual(out.map(\.pts), [0.02, 0.04])
        runtime.reset()
        XCTAssertEqual(try runtime.process(VideoFrame(pixelBuffer: makeBuffer(), pts: 10, duration: 0.04)).map(\.pts), [10])
    }

    func testIFRNetRealModelProducesMidpoint() throws {
        let processor = IFRNetProcessor()
        _ = try processor.process(VideoFrame(pixelBuffer: makeBuffer(width: 128, height: 72), pts: 0, duration: 1 / 24))
        let out = try processor.process(VideoFrame(pixelBuffer: makeBuffer(width: 128, height: 72), pts: 1 / 24, duration: 1 / 24))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].pts, 1 / 48, accuracy: 0.00001)
        XCTAssertEqual(CVPixelBufferGetWidth(out[0].pixelBuffer), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(out[0].pixelBuffer), 72)
        XCTAssertNotNil(processor.lastTimings["model"])
    }

    func testIFRNetRejectsUnsupportedDimensionsWithReason() throws {
        let processor = IFRNetProcessor()
        XCTAssertThrowsError(try processor.process(VideoFrame(pixelBuffer: makeBuffer(width: 1920, height: 1200), pts: 0, duration: 1 / 24))) { error in
            XCTAssertTrue(error.localizedDescription.contains("1920×1200"))
        }
    }

    func testFastRealProcessorRepeatedLifecycle() throws {
        for _ in 0..<5 {
            try autoreleasepool {
                let processor = VTInterpolationProcessor()
                _ = try processor.process(VideoFrame(pixelBuffer: makeBuffer(width: 1920, height: 1080), pts: 0, duration: 1 / 24))
                let out = try processor.process(VideoFrame(pixelBuffer: makeBuffer(width: 1920, height: 1080), pts: 1 / 24, duration: 1 / 24))
                XCTAssertEqual(out.count, 2)
                XCTAssertEqual(out[0].pts, 1 / 48, accuracy: 0.00001)
                processor.reset()
            }
        }
    }

    private func makeBuffer(width: Int = 16, height: Int = 16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HaoPlayerTests", code: 6)
        }
        return buffer
    }
}

final class FakeInterpolator: FrameProcessor {
    private var previous: VideoFrame?

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        guard let previous else {
            self.previous = frame
            return [frame]
        }
        let mid = VideoFrame(
            pixelBuffer: previous.pixelBuffer,
            pts: (previous.pts + frame.pts) / 2,
            duration: frame.duration / 2
        )
        self.previous = frame
        return [mid, frame]
    }

    func reset() {
        previous = nil
    }
}

final class ThrowingInterpolator: FrameProcessor {
    private var previous: VideoFrame?

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        if previous == nil {
            previous = frame
            return [frame]
        }
        throw InterpolationError.unavailable
    }

    func reset() {
        previous = nil
    }
}
