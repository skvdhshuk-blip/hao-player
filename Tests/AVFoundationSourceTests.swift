import AVFoundation
import XCTest
@testable import HaoPlayer

final class AVFoundationSourceTests: XCTestCase {
    func testPullsVideoThenSeekAdvances() async throws {
        let url = try await TestMedia.writeTinyMP4()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = AVFoundationSource()
        try await source.open(url)
        XCTAssertGreaterThan(source.duration, 0)

        var firstPTS: Double?
        for _ in 0..<40 {
            switch try source.pull() {
            case .video(let frame):
                firstPTS = frame.pts
                XCTAssertEqual(frame.duration, 1 / 15, accuracy: 0.002, "Use the track frame rate when sample duration is absent")
            case .eof:
                break
            case .audio:
                continue
            }
            if firstPTS != nil { break }
        }
        let start = try XCTUnwrap(firstPTS)

        try source.seek(to: max(source.duration * 0.6, 0.04))
        var laterPTS: Double?
        for _ in 0..<40 {
            switch try source.pull() {
            case .video(let frame):
                laterPTS = frame.pts
            case .eof:
                break
            case .audio:
                continue
            }
            if laterPTS != nil { break }
        }
        XCTAssertGreaterThan(try XCTUnwrap(laterPTS), start - 0.001)
    }
}

private enum TestMedia {
    static func writeTinyMP4() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-avf-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for index in 0..<15 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                64,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            )
            guard let buffer else {
                throw NSError(domain: "HaoPlayerTests", code: 3)
            }
            let time = CMTime(value: CMTimeValue(index), timescale: 15)
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "HaoPlayerTests", code: 2)
        }
        return url
    }
}
