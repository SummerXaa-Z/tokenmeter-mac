import XCTest
@testable import TokenMeter

final class SourceCollectionPresentationTests: XCTestCase {
    func testReadFailureAndLastGoodDataCoexistForEveryLocalTool() {
        let value = SourceCollectionPresentation(hasResult: true, loading: false, error: "读取失败")
        XCTAssertEqual(value.content, .data)
        XCTAssertEqual(value.error, "读取失败")
        XCTAssertTrue(value.showingLastGood)
    }

    func testConfirmedZeroStillHasDataWhileNoResultDoesNot() {
        XCTAssertEqual(SourceCollectionPresentation(hasResult: true, loading: false, error: nil).content, .data)
        let unavailable = SourceCollectionPresentation(hasResult: false, loading: false, error: nil)
        XCTAssertEqual(unavailable.content, .empty)
        XCTAssertFalse(unavailable.showingLastGood)
    }

    func testLoadingRetainsExistingDataAndFailureDoesNotBecomeConfirmedZero() {
        XCTAssertEqual(SourceCollectionPresentation(hasResult: true, loading: true, error: nil).content, .data)
        XCTAssertEqual(SourceCollectionPresentation(hasResult: false, loading: true, error: nil).content, .loading)
        let failure = SourceCollectionPresentation(hasResult: false, loading: false, error: "无法读取")
        XCTAssertNotNil(failure.error)
        XCTAssertFalse(failure.showingLastGood)
    }
}
