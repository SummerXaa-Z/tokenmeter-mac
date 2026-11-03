import XCTest
@testable import TokenMeter

final class FrontendScopeConsistencyTests: XCTestCase {
    private let today = "2026-10-03"

    private func modelDay(_ date: String, tokens: Int) -> ModelUsageDay {
        .init(date: date, bySource: [.kimi: .init(models: ["fixture": .init(input: tokens)])])
    }

    private var freeEstimator: APICostEstimator {
        .init(snapshots: [.init(model: "fixture", aliases: [], effectiveFrom: "2026-01-01",
            currency: "USD", perMillion: .init(newInput: 0, cachedInput: 0,
                cacheCreation: 0, output: 0, reasoningOutput: nil))])
    }

    @MainActor
    func testModelEntryRangePreservesEveryOverviewTabAndKeepsRecoveryRange() {
        XCTAssertEqual(CodingModelDetailView.Span(range: .day), .day)
        XCTAssertEqual(CodingModelDetailView.Span(range: .week), .week)
        XCTAssertEqual(CodingModelDetailView.Span(range: .month), .month)
        XCTAssertEqual(CodingModelDetailView.Span(range: .all), .all)
        XCTAssertTrue(CodingModelDetailView.Span.allCases.contains(.quarter))
        XCTAssertTrue(CodingModelDetailView.Span.allCases.contains(.all))
    }

    func testModelAllIncludesOldHistoryGapsAndIgnoresFutureInsteadOfDefaultingTo30Days() throws {
        let result = try XCTUnwrap(CodingModelDetail.summary(source: .kimi, model: "fixture",
            liveDayModels: nil,
            persisted: [modelDay("2026-01-01", tokens: 10), modelDay(today, tokens: 20),
                        modelDay("2026-10-04", tokens: 999), modelDay("2026-99-99", tokens: 999)],
            todayKey: today, windowDays: 1, allHistory: true, estimator: freeEstimator))
        XCTAssertEqual(result.days.first?.date, "2026-01-01")
        XCTAssertEqual(result.days.last?.date, today)
        XCTAssertGreaterThan(result.days.count, 90)
        XCTAssertEqual(result.tally.total, 30)
        XCTAssertEqual(result.days.first { $0.date == "2026-02-01" }?.tokens, 0)
        XCTAssertEqual(result.pricedTotalUSD, 0)
    }

    func testEmptyModel30DaysCanRecoverBySwitching90DaysOrAll() throws {
        let persisted = [modelDay("2026-08-01", tokens: 100)]
        XCTAssertNil(CodingModelDetail.summary(source: .kimi, model: "fixture",
            liveDayModels: nil, persisted: persisted, todayKey: today, windowDays: 30))
        let quarter = try XCTUnwrap(CodingModelDetail.summary(source: .kimi, model: "fixture",
            liveDayModels: nil, persisted: persisted, todayKey: today, windowDays: 90))
        XCTAssertEqual(quarter.tally.total, 100)
        let all = try XCTUnwrap(CodingModelDetail.summary(source: .kimi, model: "fixture",
            liveDayModels: nil, persisted: persisted, todayKey: today, allHistory: true))
        XCTAssertEqual(all.days.first?.date, "2026-08-01")
    }

    func testModelOneDayNeverIncludesYesterdayAndAllHonorsLiveReplacement() throws {
        let persisted = [modelDay("2026-10-02", tokens: 100), modelDay(today, tokens: 20)]
        let one = try XCTUnwrap(CodingModelDetail.summary(source: .kimi, model: "fixture",
            liveDayModels: nil, persisted: persisted, todayKey: today, windowDays: 1))
        XCTAssertEqual(one.days.map(\.date), [today])
        XCTAssertEqual(one.tally.total, 20)
        let all = try XCTUnwrap(CodingModelDetail.summary(source: .kimi, model: "fixture",
            liveDayModels: ["2026-10-02": [:]], persisted: persisted,
            todayKey: today, allHistory: true))
        XCTAssertEqual(all.days.map(\.date), [today])
        XCTAssertEqual(all.tally.total, 20)
    }

    func testModelTrendSeparatesUnknownFreeAndNoTokenAmounts() {
        let points = CodingModelDetail.trendValues(from: [
            .init(date: "2026-10-01", usd: 0, tally: .init(input: 100), hasPrice: false),
            .init(date: "2026-10-02", usd: 0, tally: .init(input: 100), hasPrice: true),
            .init(date: today, usd: 0, tally: .init()),
        ], granularity: .day)
        XCTAssertEqual(points.map(\.key), ["2026-10-01", "2026-10-02", today])
        XCTAssertNil(points[0].pricedUSD)
        XCTAssertEqual(points[1].pricedUSD, 0)
        XCTAssertEqual(points[2].pricedUSD, 0)
        XCTAssertFalse(points.contains { $0.isPartial })
    }

    @MainActor
    func testModelAmountCaptionExplainsUnknownFreeZeroAndPartialBuckets() {
        let unknown = CodingModelDetail.TrendValue(key: today, label: "10/03",
            tally: .init(input: 1), pricedUSD: nil, isPartial: false)
        let free = CodingModelDetail.TrendValue(key: today, label: "10/03",
            tally: .init(input: 1), pricedUSD: 0, isPartial: false)
        let empty = CodingModelDetail.TrendValue(key: today, label: "10/03",
            tally: .init(), pricedUSD: 0, isPartial: false)
        let partial = CodingModelDetail.TrendValue(key: today, label: "10/03",
            tally: .init(input: 2), pricedUSD: 1, isPartial: true)
        XCTAssertTrue(CodingModelDetailView.amountCaption(unknown).contains("未知"))
        XCTAssertTrue(CodingModelDetailView.amountCaption(free).contains("已知零价"))
        XCTAssertTrue(CodingModelDetailView.amountCaption(empty).contains("无 Token"))
        XCTAssertTrue(CodingModelDetailView.amountCaption(partial).contains("至少"))
    }

    func testModelWeekAndMonthBucketsKeepMissingPriceAndFullDateKeys() {
        let days: [CodingModelDetail.DayValue] = [
            .init(date: "2025-12-31", usd: 0, tally: .init(input: 100), hasPrice: false),
            .init(date: "2026-01-01", usd: 2, tally: .init(output: 200)),
            .init(date: "2026-01-02", usd: 0, tally: .init()),
            .init(date: "2026-01-05", usd: 0, tally: .init(input: 300), hasPrice: false),
        ]
        let weeks = CodingModelDetail.trendValues(from: days, granularity: .week)
        XCTAssertEqual(weeks.map(\.key), ["2025-12-29", "2026-01-05"])
        XCTAssertEqual(weeks[0].pricedUSD, 2)
        XCTAssertTrue(weeks[0].isPartial)
        XCTAssertNil(weeks[1].pricedUSD)
        let months = CodingModelDetail.trendValues(from: days, granularity: .month)
        XCTAssertEqual(months.map(\.key), ["2025-12-01", "2026-01-01"])
        XCTAssertNil(months[0].pricedUSD)
        XCTAssertEqual(months[1].pricedUSD, 2)
        XCTAssertTrue(months[1].isPartial)
    }

    func testModelCSVAllMonthUsesSameOptionalPriceAsChartAndRealScope() {
        let csv = CodingModelDetailCSVExport.makeCSV(source: .kimi, model: "fixture", spanDays: 0,
            rows: [.init(bucket: "2026-01-01", tokens: 100, usd: nil),
                   .init(bucket: "2026-02-01", tokens: 100, usd: 0),
                   .init(bucket: "2026-03-01", tokens: 0, usd: 0)],
            coverage: 0.5, todayKey: today, scopeTitle: "全部本机历史", granularity: .month)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "月(月首),Token,API等价(USD)")
        XCTAssertEqual(lines[1], "2026-01-01,100,")
        XCTAssertEqual(lines[2], "2026-02-01,100,0.00")
        XCTAssertEqual(lines[3], "2026-03-01,0,0.00")
        XCTAssertTrue(csv.contains("全部本机历史"))
        XCTAssertTrue(csv.contains("部分计价金额为下限"))
        XCTAssertFalse(csv.contains("近 0 天"))
        XCTAssertFalse(csv.contains("90 天档"))
    }

    func testTodayConfirmationDoesNotTurnOldSnapshotOrReadFailureIntoZeroComparison() {
        let old = KimiUsageResult(days: [.init(date: "2026-10-02", inputTokens: 100)],
            models: [], todayHours: [])
        let stale = SourceTodayConfirmation(liveTokens: old.dailyTokens(on: today), recordedTokens: nil,
            presentation: .init(hasResult: true, loading: false, error: nil))
        XCTAssertNil(stale.tokens)
        XCTAssertEqual(stale.phase, .unknown)
        XCTAssertFalse(stale.canCompare)
        XCTAssertEqual(stale.text, "今日尚未确认")
        let failed = SourceTodayConfirmation(liveTokens: 100, recordedTokens: 100,
            presentation: .init(hasResult: true, loading: false, error: "合成读取失败"))
        XCTAssertEqual(failed.tokens, 100)
        XCTAssertEqual(failed.phase, .lastGood)
        XCTAssertFalse(failed.canCompare)
        XCTAssertTrue(failed.text.contains("上次成功记录"))
        let savedOnly = SourceTodayConfirmation(liveTokens: nil, recordedTokens: 100,
            presentation: .init(hasResult: false, loading: false, error: nil))
        XCTAssertEqual(savedOnly.phase, .lastGood)
        XCTAssertFalse(savedOnly.canCompare)
    }

    func testConfirmedZeroCanCompareButLoadingLastGoodZeroCannot() {
        let confirmed = SourceTodayConfirmation(liveTokens: 0, recordedTokens: 100,
            presentation: .init(hasResult: true, loading: false, error: nil))
        XCTAssertEqual(confirmed.tokens, 0)
        XCTAssertEqual(confirmed.phase, .confirmed)
        XCTAssertTrue(confirmed.canCompare)
        let loading = SourceTodayConfirmation(liveTokens: 0, recordedTokens: 100,
            presentation: .init(hasResult: true, loading: true, error: nil))
        XCTAssertEqual(loading.tokens, 0)
        XCTAssertEqual(loading.phase, .lastGood)
        XCTAssertFalse(loading.canCompare)
    }

    @MainActor
    func testSourceHistoryFixedRangesHaveContinuousDatesAnd1DIsDailyNotFakeHourly() {
        let totals = ["2026-09-01": 100, "2026-10-01": 10, today: 20, "2026-10-04": 999]
        let one = SourceHistoryTrendCard.makeBuckets(totals: totals, range: .day, todayKey: today)
        XCTAssertEqual(one.map(\.date), [today])
        XCTAssertEqual(one.map(\.value), [20])
        XCTAssertEqual(SourceHistoryTrendCard.granularity(totals: totals, range: .day, todayKey: today), .day)
        let week = SourceHistoryTrendCard.makeBuckets(totals: totals, range: .week, todayKey: today)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.date, "2026-09-27")
        XCTAssertEqual(week.first { $0.date == "2026-10-02" }?.value, 0)
        XCTAssertEqual(week.reduce(0) { $0 + $1.value }, 30)
        XCTAssertEqual(SourceHistoryTrendCard.makeBuckets(totals: totals, range: .month,
            todayKey: today).count, 30)
    }

    @MainActor
    func testSourceHistoryAllPreservesOldRecordsAndRealWeekMonthKeys() {
        let weekTotals = ["2026-01-01": 10, today: 20, "2026-10-04": 999, "2026-99-99": 999]
        let weeks = SourceHistoryTrendCard.makeBuckets(totals: weekTotals, range: .all, todayKey: today)
        XCTAssertEqual(SourceHistoryTrendCard.granularity(totals: weekTotals, range: .all, todayKey: today), .week)
        XCTAssertEqual(weeks.first?.date, "2025-12-29")
        XCTAssertEqual(weeks.last?.date, "2026-09-28")
        XCTAssertEqual(weeks.reduce(0) { $0 + $1.value }, 30)
        XCTAssertTrue(weeks.contains { $0.value == 0 })
        let monthTotals = ["2023-01-01": 10, today: 20]
        let months = SourceHistoryTrendCard.makeBuckets(totals: monthTotals, range: .all, todayKey: today)
        XCTAssertEqual(SourceHistoryTrendCard.granularity(totals: monthTotals, range: .all, todayKey: today), .month)
        XCTAssertEqual(months.first?.date, "2023-01-01")
        XCTAssertEqual(months.last?.date, "2026-10-01")
        XCTAssertEqual(months.reduce(0) { $0 + $1.value }, 30)
        XCTAssertTrue(months.contains { $0.date == "2024-01-01" && $0.value == 0 })
    }

    func testTrendHoverCaptionMatchesXAxisBucketLabels() {
        // 悬停说明与 X 轴刻度同一口径：周/月桶显示聚合合计，
        // 标签必须带上周期后缀，不能读成某一天的用量
        XCTAssertEqual(SourceHistoryTrendCard.captionLabel(granularity: .day, date: "2026-09-14"), "2026/9/14")
        XCTAssertEqual(SourceHistoryTrendCard.captionLabel(granularity: .week, date: "2026-09-14"), "9/14周")
        XCTAssertEqual(SourceHistoryTrendCard.captionLabel(granularity: .month, date: "2026-09-01"), "2026/9")
    }
}
