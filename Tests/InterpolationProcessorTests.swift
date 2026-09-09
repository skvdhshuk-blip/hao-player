import CoreML
import CoreVideo
import XCTest
@testable import HaoPlayer

final class InterpolationProcessorTests: XCTestCase {
    func testDefaultInterpolationIsOff() {
        XCTAssertEqual(EnhancementSettings().interpolation, .off)
    }

    func testOffPipelineKeepsSameBuffer() throws {
        let pipeline = PlaybackPipeline()
        let buffer = try makeBuffer()
        let frame = VideoFrame(pixelBuffer: buffer, pts: 0, duration: 0.04)
        let out = try pipeline.process(frame)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].pixelBuffer === buffer)
    }

    func testFakeInterpolatorEmitsMidpointOnSecondFrame() throws {
        let interpolator = FakeInterpolator()
        let first = VideoFrame(pixelBuffer: try makeBuffer(), pts: 0.0, duration: 0.04)
        let second = VideoFrame(pixelBuffer: try makeBuffer(), pts: 0.04, duration: 0.04)

        let out1 = try interpolator.process(first)
        XCTAssertEqual(out1.count, 1)
        XCTAssertEqual(out1[0].pts, 0.0, accuracy: 0.0001)

        let out2 = try interpolator.process(second)
        XCTAssertEqual(out2.count, 2)
        XCTAssertEqual(out2[0].pts, 0.02, accuracy: 0.0001)
        XCTAssertEqual(out2[1].pts, 0.04, accuracy: 0.0001)
        XCTAssertTrue(out2[1].pixelBuffer === second.pixelBuffer)
    }

    func testFakeInterpolatorResetReturnsSingleFrame() throws {
        let interpolator = FakeInterpolator()
        _ = try interpolator.process(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04))
        interpolator.reset()
        let out = try interpolator.process(VideoFrame(pixelBuffer: try makeBuffer(), pts: 1, duration: 0.04))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].pts, 1, accuracy: 0.0001)
    }

    func testQualityFailureDowngradesToFast() throws {
        let runtime = InterpolationRuntime(
            make: { mode in
                switch mode {
                case .off:
                    return PassthroughProcessor()
                case .fast:
                    return FakeInterpolator()
                case .quality:
                    return ThrowingInterpolator()
                }
            }
        )
        runtime.setRequested(.quality)
        XCTAssertEqual(runtime.active, .quality)

        let first = VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04)
        let second = VideoFrame(pixelBuffer: try makeBuffer(), pts: 0.04, duration: 0.04)
        XCTAssertEqual(try runtime.process(first).count, 1)

        let out = runtime.process(second)
        XCTAssertEqual(runtime.active, .fast)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].pts, 0.04, accuracy: 0.0001)
    }

    func testOverloadDowngradesQualityToFast() throws {
        let runtime = InterpolationRuntime(
            make: { mode in
                switch mode {
                case .quality:
                    return FakeInterpolator()
                case .fast:
                    return PassthroughProcessor()
                case .off:
                    return PassthroughProcessor()
                }
            }
        )
        runtime.setRequested(.quality)
        let frame = VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04)
        _ = runtime.process(frame)
        for _ in 0..<8 {
            runtime.noteProcessDuration(0.04, sourceInterval: 0.04)
        }
        XCTAssertEqual(runtime.active, .fast)
    }

    func testSingleOverBudgetFrameDowngradesImmediately() throws {
        let runtime = InterpolationRuntime(
            make: { mode in
                switch mode {
                case .quality:
                    return FakeInterpolator()
                default:
                    return PassthroughProcessor()
                }
            }
        )
        runtime.setRequested(.quality)
        _ = runtime.process(VideoFrame(pixelBuffer: try makeBuffer(), pts: 0, duration: 0.04))
        runtime.noteProcessDuration(0.2, sourceInterval: 0.04)
        XCTAssertEqual(runtime.active, .fast)
    }

    func testPixelBufferReadsFloat16Planes() throws {
        let array = try MLMultiArray(shape: [1, 3, 2, 2], dataType: .float16)
        for y in 0..<2 {
            for x in 0..<2 {
                array[[0, 0, y, x] as [NSNumber]] = 1
                array[[0, 1, y, x] as [NSNumber]] = 0.5
                array[[0, 2, y, x] as [NSNumber]] = 0
            }
        }
        let buffer = try IFRNetTensor.pixelBuffer(from: array, width: 2, height: 2)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return XCTFail("missing pixel buffer")
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(ptr[0], 0)
        XCTAssertEqual(ptr[1], 128)
        XCTAssertEqual(ptr[2], 255)
        XCTAssertEqual(ptr[3], 255)
    }

    func testIFRNetEmitsMidpointWhenModelAvailable() throws {
        let interpolator = IFRNetProcessor()
        let first = VideoFrame(pixelBuffer: try makeBuffer(width: 64, height: 64), pts: 0, duration: 0.04)
        let second = VideoFrame(pixelBuffer: try makeBuffer(width: 64, height: 64), pts: 0.04, duration: 0.04)
        let out1: [VideoFrame]
        do {
            out1 = try interpolator.process(first)
        } catch {
            throw XCTSkip("IFRNet-S model unavailable: \(error)")
        }
        XCTAssertEqual(out1.count, 1)
        let out2 = try interpolator.process(second)
        XCTAssertEqual(out2.count, 2)
        XCTAssertEqual(out2[0].pts, 0.02, accuracy: 0.0001)
        XCTAssertEqual(CVPixelBufferGetWidth(out2[0].pixelBuffer), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(out2[0].pixelBuffer), 64)
    }

    func testIFRNetLargeFrameFailsFastInsteadOfStalling() throws {
        let interpolator = IFRNetProcessor()
        let first = VideoFrame(pixelBuffer: try makeBuffer(width: 1280, height: 720), pts: 0, duration: 0.04)
        let second = VideoFrame(pixelBuffer: try makeBuffer(width: 1280, height: 720), pts: 0.04, duration: 0.04)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try interpolator.process(first)
            _ = try interpolator.process(second)
        } catch InterpolationError.unavailable {
            // 720p 超出 IFRNet-S 实时能力，必须立刻失败给降档，不能堵解码队列。
        } catch {
            throw XCTSkip("IFRNet-S model unavailable: \(error)")
        }
        XCTAssertLessThan(
            CFAbsoluteTimeGetCurrent() - start,
            0.4,
            "720p quality path must not block the decode loop"
        )
    }

    func testReleasingFastInterpolatorAfterUseDoesNotCrash() throws {
        let runtime = InterpolationRuntime { mode in
            switch mode {
            case .fast:
                return VTInterpolationProcessor()
            default:
                return PassthroughProcessor()
            }
        }
        runtime.setRequested(.fast)
        let first = VideoFrame(pixelBuffer: try makeBuffer(width: 128, height: 128), pts: 0, duration: 0.04)
        let second = VideoFrame(pixelBuffer: try makeBuffer(width: 128, height: 128), pts: 0.04, duration: 0.04)
        _ = runtime.process(first)
        if runtime.active != .fast {
            throw XCTSkip("VT interpolation unavailable")
        }
        _ = runtime.process(second)
        runtime.noteProcessDuration(1, sourceInterval: 0.04)
        XCTAssertEqual(runtime.active, .off)
    }

    func testOpenRestoresRequestedAfterDowngrade() {
        let runtime = InterpolationRuntime(
            make: { mode in
                switch mode {
                case .quality:
                    return ThrowingInterpolator()
                default:
                    return PassthroughProcessor()
                }
            }
        )
        runtime.setRequested(.quality)
        _ = runtime.process(VideoFrame(pixelBuffer: try! makeBuffer(), pts: 0, duration: 0.04))
        _ = runtime.process(VideoFrame(pixelBuffer: try! makeBuffer(), pts: 0.04, duration: 0.04))
        XCTAssertEqual(runtime.active, .fast)
        runtime.restoreRequested()
        XCTAssertEqual(runtime.active, .quality)
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

final class SleepThenThrowInterpolator: FrameProcessor {
    private let seconds: TimeInterval
    private var previous: VideoFrame?

    init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    func process(_ frame: VideoFrame) throws -> [VideoFrame] {
        if previous == nil {
            previous = frame
            return [frame]
        }
        Thread.sleep(forTimeInterval: seconds)
        throw InterpolationError.unavailable
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
