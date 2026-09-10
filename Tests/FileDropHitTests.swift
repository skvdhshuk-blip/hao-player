import AppKit
import XCTest
@testable import HaoPlayer

final class FileDropHitTests: XCTestCase {
    func testClickDoesNotInterceptAfterDropPasteboardRemains() {
        XCTAssertFalse(
            FileDropHit.intercepts(eventType: .leftMouseDown, dropActive: false, hasFilePasteboard: true)
        )
        XCTAssertFalse(
            FileDropHit.intercepts(eventType: .leftMouseUp, dropActive: false, hasFilePasteboard: true)
        )
    }

    func testSliderDragDoesNotInterceptAfterFilePasteboardRemains() {
        XCTAssertFalse(
            FileDropHit.intercepts(eventType: .leftMouseDragged, dropActive: false, hasFilePasteboard: true)
        )
    }

    func testActiveDropStillIntercepts() {
        XCTAssertTrue(
            FileDropHit.intercepts(eventType: .leftMouseDown, dropActive: true, hasFilePasteboard: true)
        )
    }

    func testFinderDragWithoutClickEventIntercepts() {
        XCTAssertTrue(
            FileDropHit.intercepts(eventType: nil, dropActive: false, hasFilePasteboard: true)
        )
    }

    func testIdleWindowDoesNotIntercept() {
        XCTAssertFalse(
            FileDropHit.intercepts(eventType: .mouseMoved, dropActive: false, hasFilePasteboard: false)
        )
    }
}
