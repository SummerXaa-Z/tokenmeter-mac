import XCTest
@testable import TokenMeter

final class RoundTwoAnalyticsTests: XCTestCase {
    private let today = "2026-10-03"

    private func day(_ date: String, _ sources: [HistorySource: Int]) -> HistoryStore.DayPoint {
        .init(date: date, bySource: sources, cost: 0)
    }

    private func models(_ date: String, _ sources: [HistorySource: Int], model: String = "gpt-5.4") -> ModelUsageDay {
        .init(date: date, bySource: sources.mapValues {
            .init(models: [model: .init(input: $0)])
        })
    }

    private func summary(samples: [APICostSample], missing: Int = 0) -> APIReferenceCostSummary {
        APIReferenceCostSummary(samples: samples, estimator: APIReferencePricingCatalog.estimator,
            referenceDate: today, conversionRates: APIReferencePricingCatalog.conversionRatesToUSD,
            unmodelledTokens: missing)
    }

    private func snapshot(selection: [HistorySource], daily: [HistoryStore.DayPoint], modelDays: [ModelUsageDay]) -> OverviewSnapshot {
        OverviewSnapshot(selection: .init(sources: selection), range: .day,
            history: daily, streakHistory: daily, deepSeek: nil, claude: nil, codex: nil,
            openCode: nil, gemini: nil, copilot: nil, cursor: nil,
            modelHistory: modelDays, subscriptionPlans: [.init(name: "Pro", monthlyFee: 20)], todayKey: today)
    }

    func testMissingModelTokensCannotBeOffsetByAnotherSourceOrDate() {
        let sameDay = ModelUsageCoverage.unmodelledTokens(
            dailyHistory: [day(today, [.codex: 200, .claude: 100])],
            modelHistory: [models(today, [.codex: 100, .claude: 200])],
            participants: [.codex, .claude], through: today)
        XCTAssertEqual(sameDay, 100)

        let differentDays = ModelUsageCoverage.unmodelledTokens(
            dailyHistory: [day("2026-10-02", [.codex: 200]), day(today, [.codex: 100])],
            modelHistory: [models("2026-10-02", [.codex: 100]), models(today, [.codex: 200])],
            participants: [.codex], through: today)
        XCTAssertEqual(differentDays, 100)
    }

    func testCoverageUsesLatestDaySourceAndExcludesFutureInvalidAndNoModelCapabilitySources() {
        let missing = ModelUsageCoverage.unmodelledTokens(
            dailyHistory: [day(today, [.codex: 999]), day(today, [.codex: 150, .cursor: 5_000]),
                           day("2026-10-04", [.codex: 9_999]), day("2026-99-99", [.codex: 9_999])],
            modelHistory: [models(today, [.codex: 1]), models(today, [.codex: 100])],
            participants: [.codex, .cursor], through: today)
        XCTAssertEqual(missing, 50)
    }

    func testSplitSourceRowsCannotEraseAnotherSourceModelDetail() {
        let totals = [day(today, [.codex: 100]), day(today, [.claude: 100])]
        let details = [models(today, [.codex: 100]), models(today, [.claude: 100])]
        XCTAssertEqual(ModelUsageCoverage.unmodelledTokens(
            dailyHistory: totals, modelHistory: details,
            participants: [.codex, .claude], through: today), 0)
        XCTAssertEqual(ModelUsageCoverage.unmodelledTokens(
            dailyHistory: totals, modelHistory: details,
            participants: [.codex], through: today), 0)
        XCTAssertEqual(ModelUsageCoverage.unmodelledTokens(
            dailyHistory: totals, modelHistory: details + [models(today, [.codex: 0])],
            participants: [.codex, .claude], through: today), 100)
    }

    func testUnmodelledUsageIsUnknownRatherThanKnownZeroAndSuppressesComparisons() {
        let missingOnly = summary(samples: [], missing: 200)
        XCTAssertNil(missingOnly.pricedTotal)
        XCTAssertFalse(missingOnly.isFullyPriced)
        XCTAssertEqual(missingOnly.coverage, 0)

        let sample = APICostSample(model: "gpt-5.4", tokens: ModelTokenTally(input: 100).breakdown)
        let full = summary(samples: [sample])
        let partial = summary(samples: [sample], missing: 100)
        XCTAssertNotNil(partial.pricedTotal)
        XCTAssertEqual(partial.coverage, 0.5)
        XCTAssertNil(partial.changeCompared(to: full))
        XCTAssertNil(full.changeCompared(to: partial))

        let freeEstimator = APICostEstimator(snapshots: [.init(model: "free", aliases: [], effectiveFrom: today,
            currency: "USD", perMillion: .init(newInput: 0, cachedInput: 0, cacheCreation: 0, output: 0, reasoningOutput: nil))])
        let free = APIReferenceCostSummary(samples: [.init(model: "free", tokens: ModelTokenTally(input: 100).breakdown)],
            estimator: freeEstimator, referenceDate: today)
        XCTAssertEqual(free.pricedTotal, 0)
        XCTAssertTrue(free.isFullyPriced)
    }

    func testOverviewReportsPerSourceGapAndSharedPartialPricing() {
        let value = snapshot(selection: [.codex, .claude],
            daily: [day(today, [.codex: 200, .claude: 100])],
            modelDays: [models(today, [.codex: 100, .claude: 200])])
        XCTAssertEqual(value.periodTotal, 300)
        XCTAssertEqual(value.unmodelledTokens, 100)
        XCTAssertTrue(value.modelCoverageIsPartial)
        XCTAssertFalse(value.apiReferenceCost.isFullyPriced)
        XCTAssertEqual(value.apiReferenceCost.coverage, 0.75)
        XCTAssertEqual(value.subscriptionValue?.priceCoverage, 0.75)
        XCTAssertTrue(value.subscriptionValue?.multipleLabel.hasPrefix("至少") == true)
    }

    func testDisabledSourceDoesNotLowerSelectedCoverage() {
        let value = snapshot(selection: [.codex],
            daily: [day(today, [.codex: 100, .claude: 200, .cursor: 1_000])],
            modelDays: [models(today, [.codex: 100, .claude: 10])])
        XCTAssertEqual(value.periodTotal, 100)
        XCTAssertEqual(value.unmodelledTokens, 0)
        XCTAssertTrue(value.apiReferenceCost.isFullyPriced)
        XCTAssertEqual(value.apiReferenceCost.coverage, 1)
    }

    func testCSVExcludesFuturePricesAndClampsFixedWindowFeeToToday() throws {
        let modelDays = [models("2026-10-01", [.codex: 1_000_000]),
                         models("2026-10-04", [.codex: 1_000_000], model: "future-private-model")]
        let csv = UsageCSVExport.makeCSV(
            [day("2026-10-01", [.codex: 1_000_000]), day(today, [:]), day("2026-10-04", [.codex: 1_000_000])],
            apiValueByDate: UsageCSVExport.apiValueByDate(modelDays), modelHistory: modelDays,
            plans: [.init(name: "Pro", monthlyFee: 20)],
            range: .window(start: "2026-10-01", end: "2026-10-31"), todayKey: today)
        XCTAssertFalse(csv.contains("future-private-model"))
        XCTAssertFalse(csv.contains("2026-10-04"))
        XCTAssertTrue(csv.contains("覆盖率 100.0%"), csv)
        XCTAssertTrue(csv.contains("折算天数 3"), csv)
        XCTAssertFalse(csv.contains("折算天数 31"))
    }

    func testCSVPriceCoverageAndROIAgreeOnPerSourceMissingModels() {
        let daily = [day(today, [.codex: 2_000_000, .claude: 1_000_000, .cursor: 9_000_000])]
        let modelDays = [models(today, [.codex: 1_000_000, .claude: 2_000_000])]
        let csv = UsageCSVExport.makeCSV(daily,
            apiValueByDate: UsageCSVExport.apiValueByDate(modelDays), modelHistory: modelDays,
            plans: [.init(name: "Pro", monthlyFee: 20)], todayKey: today)
        XCTAssertTrue(csv.contains("覆盖率 75.0%"), csv)
        XCTAssertTrue(csv.contains("覆盖 tokens 3000000 / 4000000"), csv)
        XCTAssertTrue(csv.contains("无模型明细 tokens 1000000"), csv)
        XCTAssertTrue(csv.contains("回本倍数下限"), csv)
    }

    func testWeeklyROIAndSourceSubscriptionDoNotOffsetDifferentDayGaps() throws {
        let daily = [day("2026-09-23", [.codex: 200]), day("2026-09-24", [.codex: 100])]
        let modelDays = [models("2026-09-23", [.codex: 100]), models("2026-09-24", [.codex: 200])]
        let point = try XCTUnwrap(SubscriptionROICurve.weeklyPoints(participants: [.codex],
            monthlyFeeUSD: 20, persisted: modelDays, dailyHistory: daily,
            today: DateUtil.date(from: today)!, weeks: 1).last)
        XCTAssertEqual(point.priceCoverage, 0.75)
        XCTAssertTrue(point.isPartial)
        let subscription = try XCTUnwrap(SourceAPICost.subscriptionValue(source: .codex,
            liveDayModels: nil, period: .month, plans: [.init(name: "Pro", monthlyFee: 20, source: .codex)],
            persisted: modelDays, dailyHistory: daily, todayKey: "2026-09-24"))
        XCTAssertEqual(subscription.priceCoverage, 0.75)
    }

    func testFutureOnlyModelDetailDoesNotInventHistoricROIPoints() {
        XCTAssertTrue(SubscriptionROICurve.weeklyPoints(participants: [.codex], monthlyFeeUSD: 20,
            persisted: [models("2026-10-04", [.codex: 100])],
            today: DateUtil.date(from: today)!).isEmpty)
    }

    func testSourceMainCostCardRetainsPartialAmountButDoesNotCompareIncompleteWindows() throws {
        let daily = [day("2026-09-20", [.codex: 100]), day("2026-09-23", [.codex: 200]),
                     day("2026-09-24", [.codex: 100])]
        let modelDays = [models("2026-09-20", [.codex: 100]), models("2026-09-23", [.codex: 100]),
                         models("2026-09-24", [.codex: 200])]
        let current = try XCTUnwrap(SourceAPICost.summary(source: .codex, liveDayModels: nil,
            period: .rolling7, persisted: modelDays, dailyHistory: daily, todayKey: "2026-09-27"))
        let prior = try XCTUnwrap(SourceAPICost.priorSummary(source: .codex, liveDayModels: nil,
            period: .rolling7, persisted: modelDays, dailyHistory: daily, todayKey: "2026-09-27"))
        XCTAssertNotNil(current.pricedTotal)
        XCTAssertEqual(current.coverage, 0.75)
        XCTAssertFalse(current.isFullyPriced)
        XCTAssertTrue(prior.isFullyPriced)
        XCTAssertNil(current.changeCompared(to: prior))
    }

    func testSourceMainCostCardWithOnlyUnmodelledUsageIsUnknown() throws {
        let value = try XCTUnwrap(SourceAPICost.summary(source: .codex, liveDayModels: nil,
            persisted: [], dailyHistory: [day(today, [.codex: 100])], todayKey: today))
        XCTAssertEqual(value.coverage, 0)
        XCTAssertEqual(value.unmodelledTokens, 100)
        XCTAssertNil(value.pricedTotal)
        XCTAssertFalse(value.isFullyPriced)
    }
}
