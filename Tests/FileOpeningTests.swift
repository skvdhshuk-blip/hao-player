import XCTest
@testable import HaoPlayer

final class FileOpeningTests: XCTestCase {
    func testDisplayNameUsesSuggestedNameForItemProviderTemp() {
        let url = URL(fileURLWithPath: "/tmp/.com.apple.Foundation.NSItemProvider.2KT2Jy.tmp")
        XCTAssertEqual(
            FileOpening.displayName(url: url, suggestedName: "sample_1280x720_surfing_with_audio.mkv"),
            "sample_1280x720_surfing_with_audio.mkv"
        )
    }

    func testDisplayNameKeepsRealFileName() {
        let url = URL(fileURLWithPath: "/Users/me/Movies/clip.mkv")
        XCTAssertEqual(FileOpening.displayName(url: url, suggestedName: "other.mp4"), "clip.mkv")
    }

    func testIngestFileURLsUsesFirstRealFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hao-drop-test.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: url)
        let drop = try FileOpening.ingestFileURLs([url])
        XCTAssertEqual(drop.displayName, "hao-drop-test.mkv")
        XCTAssertFalse(drop.bookmark.isEmpty)
    }

    func testIngestFileURLsRejectsEmptyList() {
        XCTAssertThrowsError(try FileOpening.ingestFileURLs([]))
    }
}
