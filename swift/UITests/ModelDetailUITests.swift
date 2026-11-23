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

final class QwenSourceHealthUITests: XCTestCase {
    func testMissingQwenSummaryShowsScopedHelpWhenReturningToTools() {
#if DEBUG
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-smoke-window", "--ui-smoke-scenario=qwen-missing"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let scroll = window.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let hint = window.staticTexts["若使用 Qwen Code 0.x，请结束终端会话后刷新。"]
        func revealHint() -> Bool {
            for _ in 0..<3 {
                if hint.waitForExistence(timeout: 1) && hint.isHittable { return true }
                scroll.scroll(byDeltaX: 0, deltaY: -210)
            }
            return hint.exists && hint.isHittable
        }
        XCTAssertTrue(revealHint(), app.debugDescription)
        window.buttons["数据来源"].click()
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: hint)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        window.buttons["工具与维护"].click()
        XCTAssertTrue(revealHint(), app.debugDescription)
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
        let range = app.buttons["TokenMeter.Range.30D"]
        XCTAssertFalse(range.exists)
        for cycle in 0..<3 {
            statusItem.click()
            XCTAssertTrue(range.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(range.isHittable)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Real status popover open cycle \(cycle)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
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
