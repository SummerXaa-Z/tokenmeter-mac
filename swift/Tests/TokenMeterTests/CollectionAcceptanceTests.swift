import XCTest
@testable import TokenMeter

final class CollectionAcceptanceTests: XCTestCase {
    @MainActor
    func testFailedClaudeScanPreservesLastGoodAndBothHistories() throws {
        try assertIsolated()
        let state = AppState()
        let date = "2026-09-25"
        let good = ClaudeUsageResult(
            days: [.init(date: date, inputTokens: 70)], models: [], projects: [],
            todayHours: [], weekCompare: .empty, skills: [],
            dayModels: [date: ["claude-opus-4.6": .init(input: 70)]])
        XCTAssertTrue(state.acceptClaudeCollection(good))
        let history = HistoryStore.all()
        let details = ModelUsageHistoryStore.shared.all()
        let revision = state.historyRevision
        var failed = ClaudeUsageResult(
            days: [.init(date: date)], models: [], projects: [],
            todayHours: [], weekCompare: .empty, skills: [])
        failed.readError = "Claude 本地会话读取失败"

        XCTAssertFalse(state.acceptClaudeCollection(failed))
        XCTAssertEqual(state.claude.result, good)
        XCTAssertNotNil(state.claude.error)
        XCTAssertEqual(HistoryStore.all(), history)
        XCTAssertEqual(ModelUsageHistoryStore.shared.all(), details)
        XCTAssertEqual(state.historyRevision, revision)

        failed.readError = nil
        XCTAssertTrue(state.acceptClaudeCollection(failed))
        XCTAssertNil(state.claude.error)
        XCTAssertNil(HistoryStore.all().first { $0.date == date }?.bySource[.claude])
        XCTAssertNil(ModelUsageHistoryStore.shared.all().first { $0.date == date }?.bySource[.claude])
    }

    @MainActor
    func testFailedCodexScanCannotOverwriteNonzeroHistoryWithPartialData() throws {
        try assertIsolated()
        let state = AppState()
        let date = "2026-09-26"
        let good = CodexUsageResult(
            rateLimits: nil, allRateLimits: [], days: [.init(date: date, totalTokens: 70)],
            models: [], projects: [], todayHours: [], skills: [],
            dayModels: [date: ["gpt-5.4": .init(input: 70)]])
        XCTAssertTrue(state.acceptCodexCollection(good))
        let history = HistoryStore.all()
        let details = ModelUsageHistoryStore.shared.all()
        var partial = CodexUsageResult(
            rateLimits: nil, allRateLimits: [], days: [.init(date: date, totalTokens: 7)],
            models: [], projects: [], todayHours: [], skills: [],
            dayModels: [date: ["gpt-5.4": .init(input: 7)]])
        partial.readError = "Codex 本地会话读取失败"

        XCTAssertFalse(state.acceptCodexCollection(partial))
        XCTAssertEqual(state.codex.result, good)
        XCTAssertNotNil(state.codex.error)
        XCTAssertEqual(HistoryStore.all(), history)
        XCTAssertEqual(ModelUsageHistoryStore.shared.all(), details)
        XCTAssertTrue(state.acceptCodexCollection(good))
        XCTAssertNil(state.codex.error)
    }

    private func assertIsolated() throws {
        XCTAssertTrue(RuntimeEnvironment.isTesting)
        guard RuntimeEnvironment.isIsolated else { throw XCTSkip("Requires isolated test host") }
        XCTAssertTrue(RuntimeEnvironment.applicationSupportDirectory.path.hasPrefix(
            FileManager.default.temporaryDirectory.path))
    }
}
