import XCTest
@testable import HaoPlayer

final class PlaybackSessionTests: XCTestCase {
    func testOpenResetsDropBeforeAfterPreviousSeek() {
        let session = PlaybackSession()
        session.open(StubSource(duration: 120))
        session.seek(to: 88)
        XCTAssertEqual(session.dropBefore, 88, accuracy: 0.001)

        session.open(StubSource(duration: 10))
        XCTAssertEqual(session.dropBefore, 0, accuracy: 0.001)
    }
}

private final class StubSource: VideoSource {
    let duration: Double
    let hasAudio = false
    let sampleRate = 48000.0

    init(duration: Double) {
        self.duration = duration
    }

    func open(_ url: URL) async throws {}
    func seek(to time: Double) throws {}
    func pull() throws -> MediaSample { .eof }
}
