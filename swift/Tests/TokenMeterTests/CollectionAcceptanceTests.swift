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

    @MainActor
    func testNewLocalSourcesPreserveLastGoodSnapshotAndBothHistoriesOnReadFailure() throws {
        try assertIsolated()
        for source in newLocalSources {
            let state = AppState()
            setEnabled(true, source: source, state: state)
            XCTAssertTrue(acceptFixture(source, state: state, tokens: 70))
            let history = HistoryStore.all()
            let details = ModelUsageHistoryStore.shared.all()
            let revision = state.historyRevision

            XCTAssertTrue(state.acceptLocalCollectionFailure(source, message: "合成读取失败"))

            XCTAssertEqual(total(source, state: state), 70, "\(source) must retain the successful snapshot")
            XCTAssertEqual(error(source, state: state), "合成读取失败")
            XCTAssertNotNil(loadedAt(source, state: state), "Failure must retain the retry interval")
            XCTAssertEqual(HistoryStore.all(), history)
            XCTAssertEqual(ModelUsageHistoryStore.shared.all(), details)
            XCTAssertEqual(state.historyRevision, revision)

            XCTAssertTrue(acceptFixture(source, state: state, tokens: 71))
            XCTAssertEqual(total(source, state: state), 71)
            XCTAssertNil(error(source, state: state))
        }
    }

    @MainActor
    func testFailureBeforeFirstSuccessIsNotAConfirmedZeroSnapshot() throws {
        try assertIsolated()
        for source in newLocalSources {
            let state = AppState()
            setEnabled(true, source: source, state: state)
            let revision = state.historyRevision
            XCTAssertTrue(state.acceptLocalCollectionFailure(source, message: "合成读取失败"))
            XCTAssertNil(total(source, state: state))
            XCTAssertNotNil(error(source, state: state))
            XCTAssertEqual(state.historyRevision, revision)
        }
    }

    @MainActor
    func testEveryLocalSourceRejectsSuccessAndFailureFromBeforeOffOnToggle() throws {
        try assertIsolated()
        for source in [.claude, .codex] + newLocalSources {
            let state = AppState()
            setEnabled(true, source: source, state: state)
            XCTAssertTrue(acceptFixture(source, state: state, tokens: 70))
            let oldRevision = state.localCollectionRevision(for: source)
            setEnabled(false, source: source, state: state)
            XCTAssertFalse(acceptFixture(source, state: state, tokens: 700, requestRevision: oldRevision))
            setEnabled(true, source: source, state: state)
            let history = HistoryStore.all()
            let details = ModelUsageHistoryStore.shared.all()
            let historyRevision = state.historyRevision

            XCTAssertFalse(acceptFixture(source, state: state, tokens: 700, requestRevision: oldRevision))
            XCTAssertFalse(state.acceptLocalCollectionFailure(
                source, message: "旧一轮失败", requestRevision: oldRevision))
            XCTAssertEqual(total(source, state: state), 70)
            XCTAssertNil(error(source, state: state))
            XCTAssertNil(loadedAt(source, state: state), "Reopened source must request a fresh scan")
            XCTAssertEqual(HistoryStore.all(), history)
            XCTAssertEqual(ModelUsageHistoryStore.shared.all(), details)
            XCTAssertEqual(state.historyRevision, historyRevision)

            XCTAssertTrue(acceptFixture(source, state: state, tokens: 71,
                                       requestRevision: state.localCollectionRevision(for: source)))
            XCTAssertEqual(total(source, state: state), 71)
        }
    }

    @MainActor
    func testConfirmedZeroPreservesEachSourcesExistingHistoryAuthorityContract() throws {
        try assertIsolated()
        for source in newLocalSources {
            let state = AppState()
            setEnabled(true, source: source, state: state)
            XCTAssertTrue(acceptFixture(source, state: state, tokens: 70))
            XCTAssertTrue(acceptFixture(source, state: state, tokens: 0))
            XCTAssertEqual(total(source, state: state), 0, "Successful zero replaces the live snapshot")
            XCTAssertNil(error(source, state: state))
            let recorded = HistoryStore.all().first { $0.date == fixtureDate }?.bySource[source]
            let detail = ModelUsageHistoryStore.shared.all()
                .first { $0.date == fixtureDate }?.bySource[source]
            if source == .kimi || source == .qwen {
                XCTAssertNil(recorded, "Authoritative rescan removes confirmed empty history")
                XCTAssertNil(detail)
            } else {
                XCTAssertEqual(recorded, 70, "Non-authoritative sources keep their existing history semantics")
                XCTAssertEqual(detail?.models["synthetic-model"]?.total, 70)
            }
        }
    }

    private let newLocalSources: [HistorySource] = [.kimi, .opencode, .gemini, .copilot, .qwen]
    private let fixtureDate = "2026-09-28"

    @MainActor
    private func acceptFixture(
        _ source: HistorySource, state: AppState, tokens: Int, requestRevision: UInt? = nil
    ) -> Bool {
        let models: [String: [String: ModelTokenTally]] = tokens > 0
            ? [fixtureDate: ["synthetic-model": .init(input: tokens)]] : [:]
        switch source {
        case .claude:
            return state.acceptClaudeCollection(.init(
                days: [.init(date: fixtureDate, inputTokens: tokens)], models: [], projects: [],
                todayHours: [], weekCompare: .empty, skills: [], dayModels: models),
                requestRevision: requestRevision)
        case .codex:
            return state.acceptCodexCollection(.init(
                rateLimits: nil, allRateLimits: [], days: [.init(date: fixtureDate, totalTokens: tokens)],
                models: [], projects: [], todayHours: [], skills: [], dayModels: models),
                requestRevision: requestRevision)
        case .kimi:
            return state.acceptKimiCollection(.init(
                days: [.init(date: fixtureDate, inputTokens: tokens)], models: [],
                todayHours: [.init(hour: 12, totalTokens: tokens)], dayModels: models),
                requestRevision: requestRevision)
        case .opencode:
            return state.acceptOpenCodeCollection(.init(
                days: [.init(date: fixtureDate, inputTokens: tokens)], models: [],
                todayHours: [.init(hour: 12, totalTokens: tokens)], dayModels: models),
                requestRevision: requestRevision)
        case .gemini:
            return state.acceptGeminiCollection(.init(
                days: [.init(date: fixtureDate, inputTokens: tokens)], models: [],
                todayHours: [.init(hour: 12, totalTokens: tokens)], dayModels: models),
                requestRevision: requestRevision)
        case .copilot:
            return state.acceptCopilotCollection(.init(
                days: [.init(date: fixtureDate, inputTokens: tokens)], models: [], skills: [],
                dayModels: models), requestRevision: requestRevision)
        case .qwen:
            return state.acceptQwenCollection(.init(
                days: [.init(date: fixtureDate, inputTokens: tokens)], models: [],
                todayHours: [.init(hour: 12, totalTokens: tokens)], dayModels: models),
                requestRevision: requestRevision)
        case .deepseek, .cursor: return false
        }
    }

    @MainActor
    private func setEnabled(_ enabled: Bool, source: HistorySource, state: AppState) {
        switch source {
        case .claude: state.setClaudeEnabled(enabled)
        case .codex: state.setCodexEnabled(enabled)
        case .kimi: state.setKimiEnabled(enabled)
        case .opencode: state.setOpenCodeEnabled(enabled)
        case .gemini: state.setGeminiEnabled(enabled)
        case .copilot: state.setCopilotEnabled(enabled)
        case .qwen: state.setQwenEnabled(enabled)
        case .deepseek, .cursor: break
        }
    }

    @MainActor
    private func total(_ source: HistorySource, state: AppState) -> Int? {
        switch source {
        case .claude: return state.claude.result?.weekTotal
        case .codex: return state.codex.result?.weekTotal
        case .kimi: return state.kimi.result?.weekTotal
        case .opencode: return state.opencode.result?.weekTotal
        case .gemini: return state.gemini.result?.weekTotal
        case .copilot: return state.copilot.result?.weekTotal
        case .qwen: return state.qwen.result?.weekTotal
        case .deepseek, .cursor: return nil
        }
    }

    @MainActor
    private func error(_ source: HistorySource, state: AppState) -> String? {
        switch source {
        case .claude: return state.claude.error
        case .codex: return state.codex.error
        case .kimi: return state.kimi.error
        case .opencode: return state.opencode.error
        case .gemini: return state.gemini.error
        case .copilot: return state.copilot.error
        case .qwen: return state.qwen.error
        case .deepseek, .cursor: return nil
        }
    }

    @MainActor
    private func loadedAt(_ source: HistorySource, state: AppState) -> Date? {
        switch source {
        case .claude: return state.claude.loadedAt
        case .codex: return state.codex.loadedAt
        case .kimi: return state.kimi.loadedAt
        case .opencode: return state.opencode.loadedAt
        case .gemini: return state.gemini.loadedAt
        case .copilot: return state.copilot.loadedAt
        case .qwen: return state.qwen.loadedAt
        case .deepseek, .cursor: return nil
        }
    }
}
