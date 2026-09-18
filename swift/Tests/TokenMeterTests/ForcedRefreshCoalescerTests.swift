import XCTest
@testable import TokenMeter

final class ForcedRefreshCoalescerTests: XCTestCase {
    func testOrdinaryRequestDuringRefreshDoesNotQueueReplay() {
        var coalescer = ForcedRefreshCoalescer()

        XCTAssertTrue(coalescer.request(force: false))
        XCTAssertFalse(coalescer.request(force: false))
        XCTAssertFalse(coalescer.finish())
        XCTAssertFalse(coalescer.isRefreshing)
    }

    func testForcedRequestsDuringRefreshCollapseIntoOneReplay() {
        var coalescer = ForcedRefreshCoalescer()

        XCTAssertTrue(coalescer.request(force: false))
        XCTAssertFalse(coalescer.request(force: true))
        XCTAssertFalse(coalescer.request(force: true))
        XCTAssertTrue(coalescer.finish())
        XCTAssertTrue(coalescer.isRefreshing)
        XCTAssertFalse(coalescer.finish())
        XCTAssertFalse(coalescer.isRefreshing)
    }

    func testCancelDropsPendingReplay() {
        var coalescer = ForcedRefreshCoalescer()

        XCTAssertTrue(coalescer.request(force: false))
        XCTAssertFalse(coalescer.request(force: true))
        coalescer.cancel()

        XCTAssertFalse(coalescer.isRefreshing)
        XCTAssertTrue(coalescer.request(force: false))
    }

    func testChangedInputRejectsStaleResultAndQueuesReplay() {
        var coalescer = ForcedRefreshCoalescer()

        XCTAssertTrue(coalescer.request(force: false))
        XCTAssertFalse(coalescer.acceptsResult(inputIsCurrent: false))
        XCTAssertTrue(coalescer.finish())
        XCTAssertTrue(coalescer.isRefreshing)
        XCTAssertTrue(coalescer.acceptsResult(inputIsCurrent: true))
        XCTAssertFalse(coalescer.finish())
    }

    @MainActor
    func testJoinedForcedRefreshWaitsUntilOwnerResumesCompletion() async {
        let completion = RefreshCompletionWaiter()
        let registered = expectation(description: "joined refresh registered")
        let resumed = expectation(description: "joined refresh resumed")

        Task { @MainActor in
            registered.fulfill()
            await completion.wait()
            resumed.fulfill()
        }

        await fulfillment(of: [registered], timeout: 1)
        completion.resumeAll()
        await fulfillment(of: [resumed], timeout: 1)
    }
}
