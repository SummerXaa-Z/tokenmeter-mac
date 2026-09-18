import XCTest
@testable import TokenMeter

final class OverviewSnapshotTests: XCTestCase {
    func testSnapshotAppliesCodingSourceSelectionWithoutSubtractingClaudeModels() {
        let selection = OverviewSourceSelection(
            deepseek: false, claude: true, codex: true, opencode: false,
            gemini: false, copilot: false, cursor: false
        )
        let history = [
            HistoryStore.DayPoint(
                date: "2026-08-11",
                bySource: [.claude: 50, .codex: 100, .cursor: 999],
                cost: 12
            ),
            HistoryStore.DayPoint(
                date: "2026-08-12",
                bySource: [.claude: 80, .codex: 120],
                cost: 3
            ),
        ]
        let snapshot = OverviewSnapshot(
            selection: selection,
            range: .week,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: claudeResult,
            codex: codexResult,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.todayBySource[.claude], 180)
        XCTAssertEqual(snapshot.todayBySource[.codex], 200)
        XCTAssertEqual(snapshot.todayTotal, 380)
        XCTAssertEqual(snapshot.periodBySource[.claude], 130)
        XCTAssertEqual(snapshot.periodBySource[.codex], 220)
        XCTAssertEqual(snapshot.periodTotal, 350)
        XCTAssertEqual(snapshot.historyStartDate, "2026-08-11")
        XCTAssertEqual(snapshot.availableHistoryDays, 2)
        XCTAssertEqual(snapshot.profile.weeklySessions, 3)
        XCTAssertEqual(snapshot.rankings.tools.map(\.source), [.codex, .claude])
        XCTAssertEqual(snapshot.skillRankings.entries.map(\.name), ["shared-skill"])
        XCTAssertEqual(snapshot.skillRankings.entries.first?.invocationCount, 5)
        XCTAssertFalse(snapshot.trend.contains { $0.source == .cursor })
        XCTAssertEqual(snapshot.trendTotal, 350)
        XCTAssertEqual(snapshot.trendGranularity, .day)
        XCTAssertEqual(Set(snapshot.trend.map(\.date)).count, 7)
        XCTAssertNil(snapshot.deepSeekPlatformCost)
    }

    func testSnapshotReturnsEmptyAggregatesWithoutEnabledSources() {
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(
                deepseek: false, claude: false, codex: false, opencode: false,
                gemini: false, copilot: false, cursor: false
            ),
            range: .month,
            history: [],
            streakHistory: [],
            deepSeek: nil,
            claude: claudeResult,
            codex: codexResult,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil
        )

        XCTAssertEqual(snapshot.todayTotal, 0)
        XCTAssertEqual(snapshot.periodTotal, 0)
        XCTAssertTrue(snapshot.rankings.tools.isEmpty)
        XCTAssertTrue(snapshot.rankings.models.isEmpty)
        XCTAssertTrue(snapshot.skillRankings.entries.isEmpty)
        XCTAssertTrue(snapshot.trend.isEmpty)
        XCTAssertNil(snapshot.historyStartDate)
        XCTAssertEqual(snapshot.availableHistoryDays, 0)
    }

    func testNonzeroPeriodSourcesHidesZeroUsageAgentOnlyForSelectedRange() {
        let history = [
            HistoryStore.DayPoint(
                date: "2026-08-12",
                bySource: [.claude: 120, .codex: 0],
                cost: 0
            ),
        ]
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.claude, .codex]),
            range: .week,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.nonzeroPeriodSources, [.claude])
        XCTAssertEqual(snapshot.periodTotal, 120)
    }

    func testQwenParticipatesInTodayHourlyProfileModelsAndZeroFiltering() {
        var day = QwenCodeDayUsage(date: "2026-08-12")
        day.inputTokens = 40
        day.cachedInputTokens = 50
        day.outputTokens = 20
        day.reasoningTokens = 10
        day.messageCount = 3
        day.sessionCount = 1
        var model = QwenCodeModelUsage(model: "qwen3-coder")
        model.inputTokens = 40
        model.cachedInputTokens = 50
        model.outputTokens = 20
        model.reasoningTokens = 10
        model.messageCount = 3
        let qwen = QwenCodeUsageResult(
            days: [day],
            models: [model],
            todayHours: (0..<24).map {
                QwenCodeHourUsage(hour: $0, totalTokens: $0 == 9 ? 120 : 0)
            }
        )
        let history = [HistoryStore.DayPoint(
            date: "2026-08-12", bySource: [.qwen: 120, .codex: 0], cost: 0
        )]
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.qwen, .codex]),
            range: .day,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            qwen: qwen,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.periodBySource[.qwen], 120)
        XCTAssertEqual(snapshot.nonzeroPeriodSources, [.qwen])
        XCTAssertEqual(snapshot.trend.filter { $0.source == .qwen }.reduce(0) { $0 + $1.tokens }, 120)
        XCTAssertEqual(snapshot.profile.weeklySessions, 1)
        XCTAssertEqual(snapshot.rankings.models.first?.model, "qwen3-coder")
        XCTAssertEqual(snapshot.apiReferenceCost.totalTokens, 120)
    }

    func testAllHistoryUsesWeeklyBucketsAndPreservesSourceTotals() throws {
        let history = try makeHistory(start: "2026-01-01", count: 120) { index in
            [.claude: index + 1, .codex: (index + 1) * 2]
        }
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.claude, .codex]),
            range: .all,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: history.last?.date ?? ""
        )

        XCTAssertEqual(snapshot.trendGranularity, .week)
        XCTAssertEqual(snapshot.historyStartDate, "2026-01-01")
        XCTAssertEqual(snapshot.availableHistoryDays, 120)
        XCTAssertEqual(snapshot.trend.reduce(0) { $0 + $1.tokens }, snapshot.trendTotal)
        XCTAssertEqual(
            snapshot.trend.filter { $0.source == .claude }.reduce(0) { $0 + $1.tokens },
            snapshot.periodBySource[.claude]
        )
        XCTAssertEqual(
            snapshot.trend.filter { $0.source == .codex }.reduce(0) { $0 + $1.tokens },
            snapshot.periodBySource[.codex]
        )
        XCTAssertTrue(snapshot.trend.allSatisfy { $0.label.hasSuffix("周") })
        XCTAssertLessThan(Set(snapshot.trend.map(\.date)).count, history.count)
    }

    func testAllHistoryKeepsAnEmptyWeeklyBucketBetweenUsedWeeks() throws {
        let history = try makeHistory(start: "2026-01-01", count: 120) { index in
            [.codex: index == 0 || index == 119 ? 10 : 0]
        }
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.codex]),
            range: .all,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: history.last?.date ?? ""
        )

        XCTAssertEqual(snapshot.trendGranularity, .week)
        XCTAssertEqual(snapshot.trendTotal, 20)
        XCTAssertGreaterThan(Set(snapshot.trend.map(\.date)).count, 10)
        XCTAssertTrue(snapshot.trend.contains { $0.tokens == 0 })
    }

    func testAllHistoryUsesMonthlyBucketsAfterTwoYears() throws {
        let history = try makeHistory(start: "2024-01-01", count: 731) { _ in
            [.codex: 10]
        }
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.codex]),
            range: .all,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: history.last?.date ?? ""
        )

        XCTAssertEqual(snapshot.trendGranularity, .month)
        XCTAssertEqual(snapshot.trendTotal, 7_310)
        XCTAssertEqual(snapshot.trend.reduce(0) { $0 + $1.tokens }, 7_310)
        XCTAssertTrue(snapshot.trend.allSatisfy { $0.label.contains("/") })
        XCTAssertLessThan(snapshot.trend.count, 30)
    }

    func testDayRangeUsesFreshLocalScanBeforeHistoryIsPersisted() {
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.codex]),
            range: .day,
            history: [],
            streakHistory: [],
            deepSeek: nil,
            claude: nil,
            codex: codexResult,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.periodBySource[.codex], 200)
        XCTAssertEqual(snapshot.periodTotal, 200)
        XCTAssertEqual(snapshot.historyStartDate, "2026-08-12")
        XCTAssertEqual(snapshot.availableHistoryDays, 1)
        XCTAssertEqual(snapshot.trendGranularity, .hour)
        XCTAssertEqual(snapshot.trend.count, 24)
        XCTAssertEqual(Set(snapshot.trend.compactMap(\.hour)), Set(0..<24))
        XCTAssertEqual(snapshot.trend.first { $0.hour == 2 }?.tokens, 80)
        XCTAssertEqual(snapshot.trend.first { $0.hour == 5 }?.tokens, 0)
        XCTAssertEqual(snapshot.trend.first { $0.hour == 8 }?.tokens, 120)
        XCTAssertEqual(snapshot.trendTotal, 200)
        XCTAssertTrue(snapshot.hourlyUnattributedSources.isEmpty)
    }

    func testDayRangeKeepsClaudeDeepSeekModelUsageInClaudeTotal() {
        var day = ClaudeDayUsage(date: "2026-08-12")
        day.inputTokens = 60
        day.deepseekBackendTokens = 60
        let result = ClaudeUsageResult(
            days: [day], models: [], projects: [],
            todayHours: [ClaudeHourUsage(
                hour: 10, totalTokens: 60, deepseekBackendTokens: 60
            )],
            weekCompare: .empty, skills: []
        )
        let history = [HistoryStore.DayPoint(
            date: "2026-08-12", bySource: [.claude: 999], cost: 0
        )]
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.claude]),
            range: .day,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: result,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.periodBySource[.claude], 60)
        XCTAssertEqual(snapshot.periodTotal, 60)
        XCTAssertEqual(snapshot.trendTotal, 60)
        XCTAssertTrue(snapshot.hourlyUnattributedSources.isEmpty)
    }

    func testDeepSeekPlatformDataStaysOutsideCodingTotalsAndReferenceCost() {
        let usageDay = UsageDay(
            date: "2026-08-12",
            flashTokens: 70,
            flashCacheHit: 10,
            flashCacheMiss: 40,
            flashResponse: 20,
            proTokens: 30,
            proCacheHit: 0,
            proCacheMiss: 20,
            proResponse: 10,
            totalTokens: 100,
            totalCost: 1.25
        )
        let history = [HistoryStore.DayPoint(
            date: "2026-08-12",
            bySource: [.deepseek: 100, .claude: 80],
            cost: 1.25,
            costBySource: [.deepseek: 1.25]
        )]
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.deepseek, .claude]),
            range: .day,
            history: history,
            streakHistory: history,
            deepSeek: UsageResult(models: [], days: [usageDay], monthCost: 1.25),
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.selection.sources, [.claude])
        XCTAssertEqual(snapshot.periodTotal, 80)
        XCTAssertNil(snapshot.periodBySource[.deepseek])
        XCTAssertEqual(snapshot.deepSeekPlatformTokens, 100)
        XCTAssertEqual(snapshot.deepSeekPlatformCost, 1.25)
        XCTAssertFalse(snapshot.rankings.tools.contains { $0.source == .deepseek })
        XCTAssertFalse(snapshot.rankings.models.contains { $0.source == .deepseek })
        XCTAssertEqual(snapshot.apiReferenceCost.totalTokens, 0)
    }

    func testOlderPlatformHistoryDoesNotExtendAllCodingTrendAxis() throws {
        let start = try XCTUnwrap(DateUtil.date(from: "2026-01-01"))
        let history = (0..<224).map { index in
            let date = DateUtil.key(DateUtil.addDays(start, index))
            return HistoryStore.DayPoint(
                date: date,
                bySource: index == 0
                    ? [.deepseek: 100]
                    : (index >= 217 ? [.codex: 10] : [:]),
                cost: index == 0 ? 1 : 0,
                costBySource: index == 0 ? [.deepseek: 1] : [:]
            )
        }
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.deepseek, .codex]),
            range: .all,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.historyStartDate, "2026-08-06")
        XCTAssertEqual(snapshot.availableHistoryDays, 7)
        XCTAssertEqual(snapshot.trendGranularity, .day)
        XCTAssertEqual(Set(snapshot.trend.map(\.date)), Set([
            "2026-08-06", "2026-08-07", "2026-08-08", "2026-08-09",
            "2026-08-10", "2026-08-11", "2026-08-12",
        ]))
        XCTAssertEqual(snapshot.deepSeekPlatformHistoryStartDate, "2026-01-01")
        XCTAssertEqual(snapshot.deepSeekPlatformAvailableHistoryDays, 224)
    }

    func testDayRangeWithConfirmedZeroStillKeepsTheTwentyFourHourAxis() {
        var day = CodexDayUsage(date: "2026-08-12")
        day.totalTokens = 0
        let result = CodexUsageResult(
            rateLimits: nil,
            allRateLimits: [],
            days: [day],
            models: [],
            projects: [],
            todayHours: (0..<24).map { CodexHourUsage(hour: $0, totalTokens: 0) },
            skills: []
        )
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.codex]),
            range: .day,
            history: [],
            streakHistory: [],
            deepSeek: nil,
            claude: nil,
            codex: result,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.trend.count, 24)
        XCTAssertEqual(Set(snapshot.trend.compactMap(\.hour)), Set(0..<24))
        XCTAssertEqual(snapshot.trendTotal, 0)
    }

    func testKimiParticipatesInTodayHourlyTrendProfileModelsAndCost() {
        var day = KimiDayUsage(date: "2026-08-12")
        day.inputTokens = 100
        day.cachedInputTokens = 200
        day.cacheCreationTokens = 30
        day.outputTokens = 40
        day.messageCount = 2
        day.sessionCount = 1
        let kimi = KimiUsageResult(
            days: [day],
            models: [{
                var model = KimiModelUsage(model: "k3-agent")
                model.inputTokens = 100
                model.cachedInputTokens = 200
                model.cacheCreationTokens = 30
                model.outputTokens = 40
                model.messageCount = 2
                return model
            }()],
            todayHours: (0..<24).map {
                KimiHourUsage(hour: $0, totalTokens: $0 == 9 ? 370 : 0)
            }
        )
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.kimi]),
            range: .day,
            history: [],
            streakHistory: [],
            deepSeek: nil,
            claude: nil,
            codex: nil,
            kimi: kimi,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.periodBySource[.kimi], 370)
        XCTAssertEqual(snapshot.trend.count, 24)
        XCTAssertEqual(snapshot.trend.first { $0.hour == 9 }?.tokens, 370)
        XCTAssertEqual(snapshot.trendTotal, 370)
        XCTAssertEqual(snapshot.profile.weeklySessions, 1)
        XCTAssertEqual(snapshot.profile.cachedInputTokens, 200)
        XCTAssertEqual(snapshot.rankings.models.first?.source, .kimi)
        XCTAssertEqual(snapshot.rankings.models.first?.model, "k3-agent")
        XCTAssertEqual(snapshot.apiReferenceCost.unpricedModels, [])
        XCTAssertEqual(snapshot.apiReferenceCost.matchedTokens, 370)
    }

    func testCursorTodayFailureFallsBackToHistoryButConfirmedZeroOverridesIt() {
        let history = [HistoryStore.DayPoint(
            date: "2026-08-12", bySource: [.cursor: 77], cost: 0
        )]
        func snapshot(todayTokens: Int?) -> OverviewSnapshot {
            OverviewSnapshot(
                selection: OverviewSourceSelection(sources: [.cursor]),
                range: .day,
                history: history,
                streakHistory: history,
                deepSeek: nil,
                claude: nil,
                codex: nil,
                openCode: nil,
                gemini: nil,
                copilot: nil,
                cursor: CursorUsageResult(
                    email: nil, membership: nil, startOfMonth: nil,
                    subscription: nil, models: [], totalCostCents: 0,
                    todayTokens: todayTokens
                ),
                todayKey: "2026-08-12"
            )
        }

        XCTAssertEqual(snapshot(todayTokens: nil).periodBySource[.cursor], 77)
        XCTAssertEqual(snapshot(todayTokens: 0).periodBySource[.cursor], 0)
    }

    func testDailyTrendKeepsAZeroDayBetweenTwoUsedDays() throws {
        let history = try makeHistory(start: "2026-08-10", count: 3) { index in
            [.codex: index == 1 ? 0 : 10]
        }
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.codex]),
            range: .all,
            history: history,
            streakHistory: history,
            deepSeek: nil,
            claude: nil,
            codex: nil,
            openCode: nil,
            gemini: nil,
            copilot: nil,
            cursor: nil,
            todayKey: "2026-08-12"
        )

        XCTAssertEqual(snapshot.trendGranularity, .day)
        XCTAssertEqual(Set(snapshot.trend.map(\.date)), [
            "2026-08-10", "2026-08-11", "2026-08-12",
        ])
        XCTAssertEqual(snapshot.trend.first { $0.date == "2026-08-11" }?.tokens, 0)
        XCTAssertEqual(snapshot.trendTotal, 20)
    }

    func testAuthoritativeHistoryReconcileCanLowerAndDeleteWithoutTouchingOtherDates() {
        let existing: [String: HistoryStore.DayEntry] = [
            "2026-08-10": .init(totalTokens: 10, cost: nil),
            "2026-08-11": .init(totalTokens: 100, cost: nil),
            "2026-08-12": .init(totalTokens: 100, cost: nil),
        ]

        let result = HistoryStore.reconciledBucket(existing, authoritativeDays: [
            (date: "2026-08-11", totalTokens: 40, cost: nil),
            (date: "2026-08-12", totalTokens: 0, cost: nil),
        ])

        XCTAssertEqual(result["2026-08-10"]?.totalTokens, 10)
        XCTAssertEqual(result["2026-08-11"]?.totalTokens, 40)
        XCTAssertNil(result["2026-08-12"])
    }

    private var claudeResult: ClaudeUsageResult {
        var day = ClaudeDayUsage(date: "2026-08-12")
        day.inputTokens = 100
        day.cacheCreationTokens = 10
        day.cacheReadTokens = 20
        day.outputTokens = 50
        day.sessionCount = 1
        day.deepseekBackendTokens = 60
        return ClaudeUsageResult(
            days: [day],
            models: [ClaudeModelUsage(
                model: "opus-4.8", totalTokens: 180, inputTokens: 100,
                cacheCreationTokens: 10, cacheReadTokens: 20,
                outputTokens: 50, messageCount: 1
            )],
            projects: [],
            todayHours: [
                ClaudeHourUsage(hour: 2, totalTokens: 80, deepseekBackendTokens: 0),
                ClaudeHourUsage(hour: 8, totalTokens: 100, deepseekBackendTokens: 60),
            ],
            weekCompare: .empty,
            skills: [ClaudeSkillUsage(name: "shared-skill", invocationCount: 2)]
        )
    }

    private var codexResult: CodexUsageResult {
        var day = CodexDayUsage(date: "2026-08-12")
        day.inputTokens = 140
        day.cachedInputTokens = 40
        day.outputTokens = 60
        day.totalTokens = 200
        day.sessionCount = 2
        return CodexUsageResult(
            rateLimits: nil,
            allRateLimits: [],
            days: [day],
            models: [CodexModelUsage(
                model: "gpt-5.4", totalTokens: 200, inputTokens: 140,
                cachedInputTokens: 40, outputTokens: 60, reasoningTokens: 0
            )],
            projects: [],
            todayHours: [
                CodexHourUsage(hour: 2, totalTokens: 80),
                CodexHourUsage(hour: 8, totalTokens: 120),
            ],
            skills: [CodexSkillUsage(name: "shared-skill", invocationCount: 3)]
        )
    }

    private func makeHistory(
        start: String,
        count: Int,
        values: (Int) -> [HistorySource: Int]
    ) throws -> [HistoryStore.DayPoint] {
        let startDate = try XCTUnwrap(DateUtil.date(from: start))
        return (0..<count).map { index in
            HistoryStore.DayPoint(
                date: DateUtil.key(DateUtil.addDays(startDate, index)),
                bySource: values(index),
                cost: 0
            )
        }
    }
}
