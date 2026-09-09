import XCTest
@testable import HaoPlayer

final class FFmpegVTSourceTests: XCTestCase {
    func testMissingFileFailsToOpen() async {
        let source = FFmpegVTSource()
        let url = URL(fileURLWithPath: "/tmp/hao-player-missing-\(UUID().uuidString).mkv")
        do {
            try await source.open(url)
            XCTFail("expected open to fail")
        } catch {
            XCTAssertTrue(error is SourceError)
        }
    }

    func testPullsVideoAndAudioFromSampleMKV() async throws {
        let url = URL(fileURLWithPath: "/Users/wh/Downloads/sample_1280x720_surfing_with_audio.mkv")
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: url.path), "sample mkv not readable in this sandbox")

        let source = FFmpegVTSource()
        try await source.open(url)
        XCTAssertGreaterThan(source.duration, 1)
        XCTAssertTrue(source.hasAudio)

        var sawVideo = false
        var sawAudio = false
        var firstPTS: Double?
        for _ in 0..<80 {
            switch try source.pull() {
            case .video(let frame):
                sawVideo = true
                firstPTS = firstPTS ?? frame.pts
            case .audio:
                sawAudio = true
            case .eof:
                break
            }
            if sawVideo, sawAudio { break }
        }
        XCTAssertTrue(sawVideo)
        XCTAssertTrue(sawAudio)

        try source.seek(to: 8)
        var laterPTS: Double?
        for _ in 0..<40 {
            if case .video(let frame) = try source.pull() {
                laterPTS = frame.pts
                break
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(laterPTS), try XCTUnwrap(firstPTS))
    }
}
