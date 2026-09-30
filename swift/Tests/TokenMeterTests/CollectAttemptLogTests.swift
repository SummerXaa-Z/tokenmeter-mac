import XCTest
@testable import TokenMeter

final class CollectAttemptLogTests: XCTestCase {
    override func tearDownWithError() throws {
        CollectAttemptLog.useDefaults(.standard)
    }

    private func makeSuite() throws -> UserDefaults {
        let name = "collect-attempt-tests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    private func attempt(
        _ source: HistorySource, failure: String? = nil,
        startedAgo: TimeInterval = 10, finishedAgo: TimeInterval = 2
    ) -> CollectAttemptLog.Attempt {
        let now = Date()
        return .init(
            source: source,
            startedAt: now.addingTimeInterval(-startedAgo),
            finishedAt: now.addingTimeInterval(-finishedAgo),
            failure: failure)
    }

    func testRecordPersistsAcrossCacheReset() throws {
        let suite = try makeSuite()
        CollectAttemptLog.useDefaults(suite)
        CollectAttemptLog.record(attempt(.claude))

        // 重置缓存后应从 defaults 重新读出
        CollectAttemptLog.useDefaults(suite)
        let loaded = try XCTUnwrap(CollectAttemptLog.attempt(for: .claude))
        XCTAssertTrue(loaded.succeeded)
        XCTAssertEqual(loaded.durationMS, 8000, accuracy: 40)
        XCTAssertNil(CollectAttemptLog.attempt(for: .codex))
    }

    func testRecordOverwritesSameSourceKeepsOthers() throws {
        CollectAttemptLog.useDefaults(try makeSuite())
        CollectAttemptLog.record(attempt(.kimi))
        CollectAttemptLog.record(attempt(.kimi, failure: "boom"))

        XCTAssertEqual(CollectAttemptLog.attempt(for: .kimi)?.failure, "boom")
    }

    func testSeedForPreviewDoesNotPersist() throws {
        let suite = try makeSuite()
        CollectAttemptLog.useDefaults(suite)
        CollectAttemptLog.seedForPreview(attempt(.gemini))
        XCTAssertNotNil(CollectAttemptLog.attempt(for: .gemini))

        // 缓存重置后应该消失:seed 从未写进 defaults
        CollectAttemptLog.useDefaults(suite)
        XCTAssertNil(CollectAttemptLog.attempt(for: .gemini))
    }

    func testDurationTextScalesUnits() {
        XCTAssertEqual(CollectAttemptLog.durationText(0), "0.0s")
        XCTAssertEqual(CollectAttemptLog.durationText(800), "0.8s")
        XCTAssertEqual(CollectAttemptLog.durationText(9_500), "9.5s")
        XCTAssertEqual(CollectAttemptLog.durationText(12_000), "12s")
        XCTAssertEqual(CollectAttemptLog.durationText(125_000), "2m05s")
        XCTAssertEqual(CollectAttemptLog.durationText(3_780_000), "1h03m")
        XCTAssertEqual(CollectAttemptLog.durationText(-5), "0.0s")
    }

    func testFailureSummaryStripsNewlinesAndCapsLength() {
        XCTAssertEqual(
            CollectAttemptLog.failureSummary("第一行\n第二行\r\n第三行"),
            "第一行 第二行 第三行")
        let long = String(repeating: "错", count: 300)
        let capped = CollectAttemptLog.failureSummary(long)
        XCTAssertEqual(capped.count, 140)
        XCTAssertTrue(capped.hasSuffix("…"))
        XCTAssertEqual(CollectAttemptLog.failureSummary("短消息"), "短消息")
    }
}
