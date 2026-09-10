import CoreVideo
import Metal
import XCTest
@testable import HaoPlayer

final class MetalPresenterTests: XCTestCase {
    func testGPUContextMapsBGRA() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HaoPlayerTests", code: 8)
        }
        let mapped = GPUContext.shared.map(buffer, plane: 0, format: .bgra8Unorm)
        XCTAssertEqual(mapped?.metal.width, 8)
        XCTAssertEqual(mapped?.metal.height, 8)
    }

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

    func testKeepsFutureFramesUntilTheirPresentationTime() throws {
        var frames = [try frame(pts: 249), try frame(pts: 249.04)]
        let taken = VideoDisplay.take(
            now: 244,
            frames: &frames,
            ready: true,
            late: 0.18,
            early: 0.03
        )
        XCTAssertNil(taken)
        XCTAssertEqual(frames.map(\.pts), [249, 249.04])
    }

    func testDropsEveryFrameWhenAllAreLate() throws {
        var frames = [try frame(pts: 0), try frame(pts: 0.04), try frame(pts: 0.08)]
        let taken = VideoDisplay.take(
            now: 0.5,
            frames: &frames,
            ready: true,
            late: 0.18,
            early: 0.03
        )
        XCTAssertNil(taken)
        XCTAssertTrue(frames.isEmpty)
    }

    func testShowsNewestFrameStillInsideLateWindow() throws {
        var frames = [try frame(pts: 0), try frame(pts: 0.04), try frame(pts: 0.12)]
        let taken = VideoDisplay.take(
            now: 0.2,
            frames: &frames,
            ready: true,
            late: 0.18,
            early: 0.03
        )
        XCTAssertEqual(taken?.pts ?? -1, 0.04, accuracy: 0.0001)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].pts, 0.12, accuracy: 0.0001)
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
