import CoreVideo
import XCTest
@testable import HaoPlayer

final class Anime4KProcessorTests: XCTestCase {
    func testFailedProcessorReturnsSameBuffer() throws {
        let processor = Anime4KProcessor()
        processor.forceFail()
        let buffer = try makeBuffer(width: 8, height: 8)
        let frame = VideoFrame(pixelBuffer: buffer, pts: 1, duration: 0.04)
        let out = try processor.process(frame)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].pixelBuffer === buffer)
        XCTAssertEqual(out[0].pts, 1)
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
        let out: [VideoFrame]
        do {
            out = try processor.process(frame)
        } catch {
            throw XCTSkip("Anime4K GPU unavailable: \(error)")
        }
        XCTAssertEqual(CVPixelBufferGetWidth(out[0].pixelBuffer), 16)
        XCTAssertEqual(CVPixelBufferGetHeight(out[0].pixelBuffer), 16)
        XCTAssertEqual(out[0].pts, 0)
        XCTAssertFalse(out[0].pixelBuffer === buffer)
    }

    private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HaoPlayerTests", code: 5)
        }
        return buffer
    }
}
