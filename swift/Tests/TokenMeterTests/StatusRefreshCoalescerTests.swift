import XCTest
@testable import TokenMeter

final class StatusRefreshCoalescerTests: XCTestCase {
    func testFirstRequestStartsImmediately() {
        var coalescer = StatusRefreshCoalescer()

        XCTAssertTrue(coalescer.request())
        XCTAssertTrue(coalescer.isRefreshing)
    }

    func testRequestsDuringRefreshCollapseIntoOneReplay() {
        var coalescer = StatusRefreshCoalescer()

        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.request())
        XCTAssertFalse(coalescer.request())
        XCTAssertTrue(coalescer.finish())
        XCTAssertTrue(coalescer.isRefreshing)
        XCTAssertFalse(coalescer.finish())
        XCTAssertFalse(coalescer.isRefreshing)
    }

    func testRequestAfterCompletionStartsANewRefresh() {
        var coalescer = StatusRefreshCoalescer()

        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.finish())
        XCTAssertTrue(coalescer.request())
    }
}
