import XCTest
@testable import HaoPlayer

final class ResumeStoreTests: XCTestCase {
    func testSaveAndLoad() {
        let defaults = UserDefaults(suiteName: "hao.player.tests.resume")!
        defaults.removePersistentDomain(forName: "hao.player.tests.resume")
        let store = ResumeStore(defaults: defaults)
        let bookmark = Data([1, 2, 3, 4])
        store.save(bookmark: bookmark, time: 12.5, lastPath: "clip.mp4")
        let loaded = store.load()
        XCTAssertEqual(loaded?.bookmark, bookmark)
        XCTAssertEqual(loaded?.time, 12.5)
        XCTAssertEqual(loaded?.lastPath, "clip.mp4")
    }

    func testClear() {
        let defaults = UserDefaults(suiteName: "hao.player.tests.resume.clear")!
        defaults.removePersistentDomain(forName: "hao.player.tests.resume.clear")
        let store = ResumeStore(defaults: defaults)
        store.save(bookmark: Data([9]), time: 1, lastPath: "a.mp4")
        store.clear()
        XCTAssertNil(store.load())
    }
}
