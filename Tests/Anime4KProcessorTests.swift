import CoreVideo
import XCTest
@testable import HaoPlayer

final class Anime4KProcessorTests: XCTestCase {
    func testFailedProcessorThrowsInsteadOfReturningOriginal() throws {
        let processor = Anime4KProcessor()
        processor.forceFail()
        let buffer = try makeBuffer(width: 8, height: 8)
        let frame = VideoFrame(pixelBuffer: buffer, pts: 1, duration: 0.04)
        XCTAssertThrowsError(try processor.process(frame))
    }

    func testDisabledPipelineKeepsSameBuffer() throws {
        let pipeline = PlaybackPipeline(upscaler: PassthroughProcessor())
        let buffer = try makeBuffer(width: 8, height: 8)
        let frame = VideoFrame(pixelBuffer: buffer, pts: 0, duration: 0.04)
        let out = try pipeline.process(frame)
        XCTAssertTrue(out[0].pixelBuffer === buffer)
    }

    func testFastADoublesResolution() throws {
        let processor = Anime4KProcessor()
        let buffer = try makeBuffer(width: 8, height: 8)
        let frame = VideoFrame(pixelBuffer: buffer, pts: 0, duration: 0.04)
        let out = try processor.process(frame)
        XCTAssertEqual(CVPixelBufferGetWidth(out[0].pixelBuffer), 16)
        XCTAssertEqual(CVPixelBufferGetHeight(out[0].pixelBuffer), 16)
        XCTAssertEqual(out[0].pts, 0)
        XCTAssertFalse(out[0].pixelBuffer === buffer)
    }

    func testRetainedOutputIsNotReusedAfterSixteenFrames() throws {
        let processor = Anime4KProcessor()
        let original = try processor.process(VideoFrame(pixelBuffer: makeBuffer(width: 8, height: 8), pts: 0, duration: 0.04))[0]
        for i in 1...20 {
            let out = try processor.process(VideoFrame(pixelBuffer: makeBuffer(width: 8, height: 8), pts: Double(i) * 0.04, duration: 0.04))[0]
            XCTAssertFalse(out.pixelBuffer === original.pixelBuffer)
        }
    }

    private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HaoPlayerTests", code: 5)
        }
        return buffer
    }
}
