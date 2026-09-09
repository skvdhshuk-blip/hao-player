import CoreVideo
import XCTest
@testable import HaoPlayer

final class MetalPresenterTests: XCTestCase {
    func testEmptyResizeDoesNotBecomeReady() {
        let presenter = MetalPresenter()
        XCTAssertFalse(presenter.isReady)
        presenter.resize(to: .zero, scale: 2)
        XCTAssertFalse(presenter.isReady)
    }

    func testRealResizeBecomesReadyAndEmptyDoesNotClobber() {
        let presenter = MetalPresenter()
        presenter.resize(to: CGSize(width: 640, height: 360), scale: 2)
        XCTAssertTrue(presenter.isReady)
        XCTAssertEqual(presenter.metalLayer.drawableSize.width, 1280, accuracy: 0.5)
        XCTAssertEqual(presenter.metalLayer.drawableSize.height, 720, accuracy: 0.5)

        presenter.resize(to: .zero, scale: 2)
        XCTAssertTrue(presenter.isReady)
        XCTAssertEqual(presenter.metalLayer.drawableSize.width, 1280, accuracy: 0.5)
    }
}

final class VideoDisplayTests: XCTestCase {
    func testKeepsFramesWhilePresenterNotReady() throws {
        var frames = [try frame(pts: 0), try frame(pts: 0.04), try frame(pts: 0.08)]
        let taken = VideoDisplay.take(
            now: 0.5,
            frames: &frames,
            ready: false,
            late: 0.18,
            early: 0.03
        )
        XCTAssertNil(taken)
        XCTAssertEqual(frames.count, 3)
    }

    func testShowsNewestLateFrameOnceReady() throws {
        var frames = [try frame(pts: 0), try frame(pts: 0.04), try frame(pts: 0.08)]
        let taken = VideoDisplay.take(
            now: 0.5,
            frames: &frames,
            ready: true,
            late: 0.18,
            early: 0.03
        )
        XCTAssertEqual(taken?.pts, 0.08)
        XCTAssertTrue(frames.isEmpty)
    }

    private func frame(pts: Double) throws -> VideoFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HaoPlayerTests", code: 4)
        }
        return VideoFrame(pixelBuffer: buffer, pts: pts, duration: 0.04)
    }
}
