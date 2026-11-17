import XCTest

final class ModelDetailUITests: XCTestCase {
    func testRangeRecoversFromEmptyStateAndCanReturnToIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-smoke-window", "--ui-smoke-scenario=model-empty"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let empty = window.staticTexts["近 30 天暂无该模型明细"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))

        for _ in 0..<2 {
            window.radioButtons["90D"].click()
            XCTAssertTrue(window.staticTexts["近 90 天 Token"].waitForExistence(timeout: 5))
            XCTAssertTrue(window.staticTexts["2M"].exists)
            XCTAssertFalse(empty.exists)

            window.radioButtons["30D"].click()
            XCTAssertTrue(empty.waitForExistence(timeout: 5))
            XCTAssertFalse(window.staticTexts["2M"].exists)
        }
    }
}
