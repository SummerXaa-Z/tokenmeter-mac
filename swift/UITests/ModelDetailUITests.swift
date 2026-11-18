import XCTest

final class ModelDetailUITests: XCTestCase {
    func testRangeRecoversFromEmptyStateAndCanReturnToIt() {
#if DEBUG
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
#else
        XCTFail("UI interaction validation requires a Debug build")
#endif
    }
}

final class StatusPopoverUITests: XCTestCase {
    func testRealStatusItemOpensClosesAndReopensPopover() {
#if DEBUG
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-smoke-popover"]
        app.launch()
        defer { app.terminate() }

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Initial status item accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
        let statusItem = app.descendants(matching: .any)["TokenMeter.StatusItem"].firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), app.debugDescription)
        let range = app.radioButtons["30D"]
        XCTAssertFalse(range.exists)
        for _ in 0..<3 {
            statusItem.click()
            XCTAssertTrue(range.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertNotEqual(app.state, .notRunning)
            statusItem.click()
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: range)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
            XCTAssertNotEqual(app.state, .notRunning)
        }
#else
        XCTFail("UI interaction validation requires a Debug build")
#endif
    }
}
