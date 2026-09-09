import XCTest
@testable import HaoPlayer

final class SourceRouterTests: XCTestCase {
    func testMp4UsesAVFoundation() {
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.mp4")), .avFoundation)
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.MOV")), .avFoundation)
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.m4v")), .avFoundation)
    }

    func testMkvUsesFFmpeg() {
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.mkv")), .ffmpeg)
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.webm")), .ffmpeg)
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.avi")), .ffmpeg)
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.ts")), .ffmpeg)
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.flv")), .ffmpeg)
        XCTAssertEqual(SourceRouter.kind(for: URL(fileURLWithPath: "/tmp/a.FLV")), .ffmpeg)
    }

    func testFlvMagicUsesFFmpeg() throws {
        let url = try writeFixture(
            name: ".com.apple.Foundation.NSItemProvider.flv.tmp",
            bytes: [0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00]
        )
        XCTAssertEqual(SourceRouter.kind(for: url), .ffmpeg)
    }

    func testItemProviderTmpWithEbmlUsesFFmpeg() throws {
        let url = try writeFixture(
            name: ".com.apple.Foundation.NSItemProvider.2KT2Jy.tmp",
            bytes: [0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00]
        )
        XCTAssertEqual(SourceRouter.kind(for: url), .ffmpeg)
    }

    func testItemProviderTmpWithFtypUsesAVFoundation() throws {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[4] = 0x66
        bytes[5] = 0x74
        bytes[6] = 0x79
        bytes[7] = 0x70
        let url = try writeFixture(
            name: ".com.apple.Foundation.NSItemProvider.abcd.tmp",
            bytes: bytes
        )
        XCTAssertEqual(SourceRouter.kind(for: url), .avFoundation)
    }

    func testUnsupportedMessageListsFlv() {
        let text = SourceError.unsupported("clip.wmv").localizedDescription ?? ""
        XCTAssertTrue(text.contains("flv"))
        XCTAssertTrue(text.contains("mkv"))
    }

    func testUnknownTmpStaysUnsupported() throws {
        let url = try writeFixture(name: "random.tmp", bytes: [0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(SourceRouter.kind(for: url), .unsupported)
    }

    private func writeFixture(name: String, bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}
