import XCTest
@testable import HaoPlayer

final class MediaClockTests: XCTestCase {
    func testResumeContinuesFromFrozenTime() {
        XCTAssertEqual(
            MediaClock.now(paused: false, frozen: 4, anchor: 4, elapsed: 0, duration: 183),
            4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MediaClock.now(paused: false, frozen: 4, anchor: 4, elapsed: 1.5, duration: 183),
            5.5,
            accuracy: 0.0001
        )
    }

    func testPauseIgnoresElapsedHostTime() {
        XCTAssertEqual(
            MediaClock.now(paused: true, frozen: 4, anchor: 4, elapsed: 12, duration: 183),
            4,
            accuracy: 0.0001
        )
    }

    func testClockStopsAtDuration() {
        XCTAssertEqual(
            MediaClock.now(paused: false, frozen: 0, anchor: 0, elapsed: 200, duration: 183),
            183,
            accuracy: 0.0001
        )
    }

    func testUnknownDurationDoesNotClamp() {
        XCTAssertEqual(
            MediaClock.now(paused: false, frozen: 0, anchor: 0, elapsed: 12, duration: 0),
            12,
            accuracy: 0.0001
        )
    }
}
