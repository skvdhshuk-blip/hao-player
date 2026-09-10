import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HaoPlayer

/// Opt-in real playback acceptance. Requires the explicit local fixture preparation script.
final class PerformanceAcceptanceTests: XCTestCase {
    func testNaturalFrameComparison() async throws {
        guard let folder = ProcessInfo.processInfo.environment["HAO_ACCEPTANCE_DIR"] else {
            throw XCTSkip("Explicit real-media visual acceptance requires prepared fixtures")
        }
        let directory = URL(fileURLWithPath: folder).appendingPathComponent("visual", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = FFmpegVTSource()
        try await source.open(URL(fileURLWithPath: folder).appendingPathComponent("720p24.mkv"))
        var results: [[String: Double]] = []
        for second in [2.0, 7.0, 11.0] {
            try source.seek(to: second)
            var frames: [VideoFrame] = []
            while frames.count < 3 {
                switch try source.pull() {
                case .video(let frame): if frame.pts >= second { frames.append(frame) }
                case .eof: throw SourceError.decodeFailed("Missing reference frames")
                case .audio: break
                }
            }
            let fast = VTInterpolationProcessor(), quality = IFRNetProcessor()
            _ = try fast.process(frames[0]); _ = try quality.process(frames[0])
            let fastFrame = try fast.process(frames[2])[0], qualityFrame = try quality.process(frames[2])[0]
            let images = ["left": frames[0].pixelBuffer, "truth": frames[1].pixelBuffer, "right": frames[2].pixelBuffer,
                          "fast": fastFrame.pixelBuffer, "quality": qualityFrame.pixelBuffer]
            for (name, buffer) in images {
                let image = CIImage(cvPixelBuffer: buffer)
                let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
                let url = directory.appendingPathComponent("\(Int(second))-\(name).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, cg, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            results.append(["second": second, "fast_mae_255": try imageError(fastFrame.pixelBuffer, frames[1].pixelBuffer),
                            "quality_mae_255": try imageError(qualityFrame.pixelBuffer, frames[1].pixelBuffer),
                            "repeat_mae_255": try imageError(frames[0].pixelBuffer, frames[1].pixelBuffer)])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: directory.appendingPathComponent("reference-errors.json"))
    }

    private func imageError(_ left: CVPixelBuffer, _ right: CVPixelBuffer) throws -> Double {
        let left = try PixelBufferIO.bgra(left), right = try PixelBufferIO.bgra(right)
        CVPixelBufferLockBaseAddress(left, .readOnly); CVPixelBufferLockBaseAddress(right, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(left, .readOnly); CVPixelBufferUnlockBaseAddress(right, .readOnly) }
        let a = CVPixelBufferGetBaseAddress(left)!.assumingMemoryBound(to: UInt8.self)
        let b = CVPixelBufferGetBaseAddress(right)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(left), height = CVPixelBufferGetHeight(left)
        var sum = 0.0
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 {
                    sum += Double(abs(Int(a[y * CVPixelBufferGetBytesPerRow(left) + x * 4 + channel]) - Int(b[y * CVPixelBufferGetBytesPerRow(right) + x * 4 + channel])))
                }
            }
        }
        return sum / Double(width * height * 3)
    }

}
