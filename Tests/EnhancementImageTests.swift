import CoreImage
import CoreText
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HaoPlayer

final class EnhancementImageTests: XCTestCase {
    func testQualityPoolDoesNotOverwriteRetainedOutput() throws {
        let processor = IFRNetProcessor()
        _ = try processor.process(VideoFrame(pixelBuffer: pattern(offset: 0), pts: 0, duration: 1 / 24))
        let held = try processor.process(VideoFrame(pixelBuffer: pattern(offset: 8), pts: 1 / 24, duration: 1 / 24))[0].pixelBuffer
        func bytes() -> Data {
            CVPixelBufferLockBaseAddress(held, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(held, .readOnly) }
            return Data(bytes: CVPixelBufferGetBaseAddress(held)!, count: CVPixelBufferGetBytesPerRow(held) * CVPixelBufferGetHeight(held))
        }
        let original = bytes()
        for index in 2..<12 {
            try autoreleasepool {
                let next = try processor.process(VideoFrame(pixelBuffer: pattern(offset: index * 8), pts: Double(index) / 24, duration: 1 / 24))
                XCTAssertFalse(held === next[0].pixelBuffer)
            }
        }
        XCTAssertEqual(bytes(), original)
    }

    func testStaticFramePreservesColorAndPaddingOrientation() throws {
        let processor = IFRNetProcessor()
        let input = try pattern(offset: 0)
        _ = try processor.process(VideoFrame(pixelBuffer: input, pts: 0, duration: 1 / 24))
        let out = try processor.process(VideoFrame(pixelBuffer: input, pts: 1 / 24, duration: 1 / 24))[0].pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(out), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 360)
        // Center patches are deliberately flat, far from borders/occlusions.
        for (x, y) in [(200, 120), (50, 40), (500, 300)] {
            let a = pixel(input, x: x, y: y), b = pixel(out, x: x, y: y)
            for channel in 0..<3 { XCTAssertLessThan(abs(a[channel] - b[channel]), 8, "color / crop at \(x),\(y)") }
        }
    }

    func testRealProcessorsProduceVisualEvidence() throws {
        let first = try pattern(offset: 0), next = try pattern(offset: 8), truth = try pattern(offset: 4)
        let left = VideoFrame(pixelBuffer: first, pts: 0, duration: 1 / 24)
        let right = VideoFrame(pixelBuffer: next, pts: 1 / 24, duration: 1 / 24)
        let fast = VTInterpolationProcessor(), quality = IFRNetProcessor(), anime = Anime4KProcessor()
        _ = try fast.process(left)
        _ = try quality.process(left)
        let fastMid = try fast.process(right)[0], qualityMid = try quality.process(right)[0]
        let enhanced = try anime.process(left)[0]
        XCTAssertEqual(fastMid.pts, 1 / 48, accuracy: 0.0001)
        XCTAssertEqual(qualityMid.pts, 1 / 48, accuracy: 0.0001)
        XCTAssertTrue(enhanced.trace.anime4K)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Hao Player Visual Evidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let images = ["original": first, "next": next, "ground-truth-midpoint": truth,
                      "fast-midpoint": fastMid.pixelBuffer, "quality-midpoint": qualityMid.pixelBuffer, "anime4k": enhanced.pixelBuffer]
        for (name, buffer) in images { try save(buffer, to: folder.appendingPathComponent(name + ".png")) }
        let report = ["fast_mae_255": try mae(fastMid.pixelBuffer, truth),
                      "quality_mae_255": try mae(qualityMid.pixelBuffer, truth),
                      "repeat_frame_mae_255": try mae(first, truth)]
        try JSONEncoder().encode(report).write(to: folder.appendingPathComponent("motion-error.json"))
        XCTAssertGreaterThan(try mae(fastMid.pixelBuffer, first), 0.1, "fast must not just repeat input")
        XCTAssertGreaterThan(try mae(qualityMid.pixelBuffer, first), 0.1, "quality must not just repeat input")
    }

    func testAnime4KTextLinesAndTextureEvidence() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 640 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.15, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        for y in 0..<12 {
            for x in 0..<20 {
                canvas.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 0.3 : 0.6, alpha: 1))
                canvas.fill(CGRect(x: 320 + x * 12, y: 20 + y * 12, width: 12, height: 12))
            }
        }
        canvas.setStrokeColor(CGColor(gray: 1, alpha: 1))
        canvas.setLineWidth(1)
        for index in 0..<12 {
            canvas.move(to: CGPoint(x: 20, y: 20 + index * 10))
            canvas.addLine(to: CGPoint(x: 280, y: 35 + index * 10))
        }
        canvas.strokePath()
        for (size, y) in [(12.0, 300.0), (18.0, 260.0), (28.0, 210.0)] {
            let text = NSAttributedString(string: "Anime4K 1080p - 24 / 48 fps", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            canvas.textPosition = CGPoint(x: 20, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), canvas)
        }
        let input = try pattern(offset: 0)
        CIContext().render(CIImage(cgImage: try XCTUnwrap(canvas.makeImage())), to: input)
        let output = try Anime4KProcessor().process(VideoFrame(pixelBuffer: input, pts: 0, duration: 1 / 24))[0].pixelBuffer
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Hao Player Visual Evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try save(input, to: directory.appendingPathComponent("text-lines-original.png"))
        try save(output, to: directory.appendingPathComponent("text-lines-anime4k.png"))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 720)
    }

    private func pattern(offset: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<360 {
            for x in 0..<640 {
                let sourceX = max(0, x - offset)
                let checker = (sourceX / 24 + y / 24) % 2 == 0
                var color: [UInt8] = checker ? [130, 80, 35] : [155, 95, 40]
                if sourceX >= 180 && sourceX < 250 && y >= 100 && y < 160 { color = [20, 220, 240] }
                let p = bytes + y * stride + x * 4
                p[0] = color[0]; p[1] = color[1]; p[2] = color[2]; p[3] = 255
            }
        }
        return result
    }

    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return [Int(p[0]), Int(p[1]), Int(p[2])]
    }

    private func mae(_ a: CVPixelBuffer, _ b: CVPixelBuffer) throws -> Double {
        let a = try PixelBufferIO.bgra(a), b = try PixelBufferIO.bgra(b)
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in 0..<360 {
            for x in 0..<640 {
                for c in 0..<3 {
                    sum += Double(abs(Int(pa[y * CVPixelBufferGetBytesPerRow(a) + x * 4 + c]) - Int(pb[y * CVPixelBufferGetBytesPerRow(b) + x * 4 + c])))
                }
            }
        }
        return sum / (640 * 360 * 3)
    }

    private func save(_ buffer: CVPixelBuffer, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: buffer)
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
