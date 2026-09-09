import XCTest
@testable import HaoPlayer

final class EnhancementSettingsTests: XCTestCase {
    func testDefaultsMatchProduct() {
        let settings = EnhancementSettings()
        XCTAssertTrue(settings.anime4KEnabled)
        XCTAssertEqual(settings.anime4KPreset, .fastA)
        XCTAssertFalse(settings.interpolationEnabled)
    }

    func testPipelinePassthroughKeepsOneFrame() throws {
        let pipeline = PlaybackPipeline()
        let buffer = try makeBuffer()
        let frame = VideoFrame(pixelBuffer: buffer, pts: .zero, duration: .invalid)
        let out = try pipeline.process(frame)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].pixelBuffer === buffer)
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HaoPlayerTests", code: 1)
        }
        return buffer
    }
}
