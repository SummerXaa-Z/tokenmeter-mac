import XCTest
@testable import TokenMeter

final class LiveUsageHistoryTests: XCTestCase {
    private let today = "2026-10-03"

    private func kimi(_ date: String, tokens: Int, model: String = "kimi-k2.6") -> KimiUsageResult {
        var day = KimiDayUsage(date: date)
        day.inputTokens = tokens
        day.sessionCount = tokens > 0 ? 1 : 0
        return KimiUsageResult(days: [day], models: [],
            todayHours: [.init(hour: 9, totalTokens: tokens)],
            dayModels: tokens > 0 ? [date: [model: .init(input: tokens)]] : [:])
    }

    private func snapshot(_ result: KimiUsageResult?, history: [HistoryStore.DayPoint] = [],
                          models: [ModelUsageDay] = [], range: UsageHistoryRange = .week) -> OverviewSnapshot {
        OverviewSnapshot(selection: .init(sources: [.kimi]), range: range,
            history: history, streakHistory: history, deepSeek: nil, claude: nil, codex: nil,
            kimi: result, openCode: nil, gemini: nil, copilot: nil, cursor: nil,
            modelHistory: models, subscriptionPlans: [.init(name: "Kimi", monthlyFee: 20)], todayKey: today)
    }

    func testCachedYesterdayIsNeitherTodaysTotalNorTodaysHours() {
        let scan = kimi("2026-10-02", tokens: 90)
        XCTAssertNil(scan.day(on: today))
        XCTAssertNil(scan.dailyTokens(on: today))
        XCTAssertNil(scan.hourlyTokens(on: today))
        let result = snapshot(scan, range: .day)
        XCTAssertEqual(result.todayTotal, 0)
        XCTAssertFalse(result.confirmedTodaySources.contains(.kimi))
        XCTAssertTrue(result.trend.isEmpty)
        let status = OverviewSourceCollectionStatus(provider: .kimi, loading: false,
            hasResult: false, error: nil, available: true, awaitingToday: true)
        XCTAssertTrue(OverviewSourceCollectionStatus.totalIsUnknown(0, statuses: [status]))
        XCTAssertEqual(OverviewSourceCollectionStatus.message(total: 0, statuses: [status], hasSelection: true),
                       "今日尚未刷新，用量暂不可确认")
    }

    func testWriteFailureInputsStillUseOneLiveOverlayForEveryRange() {
        let saved = [HistoryStore.DayPoint(date: today, bySource: [.kimi: 100], cost: 0)]
        let savedModels = [ModelUsageDay(date: today, bySource: [
            .kimi: .init(models: ["kimi-k2.6": .init(input: 100)])])]
        // Persistence has not changed (or failed). All UI computations must still
        // use the successful scan, without requiring an AppState or a filesystem.
        for range in [UsageHistoryRange.day, .week, .month, .all] {
            let result = snapshot(kimi(today, tokens: 200), history: saved, models: savedModels, range: range)
            XCTAssertEqual(result.periodTotal, 200)
            XCTAssertEqual(result.rankings.tools.first?.totalTokens, 200)
            XCTAssertEqual(result.rankings.models.first?.totalTokens, 200)
            XCTAssertEqual(result.profile.totalInputTokens, 200)
            XCTAssertEqual(result.profile.activeDays, 1)
            XCTAssertEqual(result.apiReferenceCost.totalTokens, 200)
            XCTAssertEqual(result.trendTotal, 200)
            XCTAssertEqual(result.mergedHistory.last?.bySource[.kimi], 200)
        }
        XCTAssertEqual(saved.last?.bySource[.kimi], 100)
    }

    func testNewLiveHistoryIsVisibleBeforeAnySuccessfulSave() {
        let result = snapshot(kimi(today, tokens: 25))
        XCTAssertEqual(result.periodTotal, 25)
        XCTAssertEqual(result.trendTotal, 25)
        XCTAssertEqual(result.availableHistoryDays, 1)
        XCTAssertEqual(result.historyStartDate, today)
    }

    func testConfirmedZeroClearsBothTodaysTotalAndCostButAbsenceDoesNot() {
        let history = [HistoryStore.DayPoint(date: today, bySource: [.kimi: 50], cost: 0)]
        let models = [ModelUsageDay(date: today, bySource: [
            .kimi: .init(models: ["kimi-k2.6": .init(input: 50)])])]
        let absent = snapshot(nil, history: history, models: models, range: .day)
        XCTAssertEqual(absent.periodTotal, 50)
        XCTAssertEqual(absent.apiReferenceCost.totalTokens, 50)
        let zero = snapshot(kimi(today, tokens: 0), history: history, models: models, range: .day)
        XCTAssertEqual(zero.periodTotal, 0)
        XCTAssertEqual(zero.apiReferenceCost.totalTokens, 0)
        XCTAssertTrue(zero.confirmedTodaySources.contains(.kimi))
    }

    func testPartialClaudeScanDoesNotOverrideLastGoodTotalsOrModels() {
        let daily = [HistoryStore.DayPoint(date: today, bySource: [.claude: 80], cost: 0)]
        let models = [ModelUsageDay(date: today, bySource: [.claude: .init(models: ["sonnet": .init(input: 80)])])]
        var day = ClaudeDayUsage(date: today); day.inputTokens = 2
        let scan = ClaudeUsageResult(days: [day], models: [], projects: [], todayHours: [],
            weekCompare: .empty, skills: [], dayModels: [today: ["sonnet": .init(input: 2)]], readError: "读取失败")
        let result = LiveUsageHistory(daily: daily, models: models, claude: scan, todayKey: today)
        XCTAssertEqual(result.daily.last?.bySource[.claude], 80)
        XCTAssertEqual(result.models.last?.bySource[.claude]?.models["sonnet"]?.total, 80)
    }

    func testOverlayKeepsZeroCalendarGapAndIgnoresFutureScan() {
        let saved = [HistoryStore.DayPoint(date: "2026-10-01", bySource: [.kimi: 10], cost: 0)]
        let result = LiveUsageHistory(daily: saved, models: [], kimi: kimi(today, tokens: 20), todayKey: today)
        XCTAssertEqual(result.daily.map(\.date), ["2026-10-01", "2026-10-02", today])
        XCTAssertEqual(result.daily[1].total, 0)
        XCTAssertEqual(LiveUsageHistory(daily: saved, models: [],
            kimi: kimi("2026-10-04", tokens: 999), todayKey: today).daily.last?.total, 0)
    }
}
