import XCTest
@testable import TokenMeter

final class UnknownReferenceCostTests: XCTestCase {
    private let date = "2026-10-03"
    private func detail(_ models: [String: ModelTokenTally], date: String = "2026-10-03") -> ModelUsageDay {
        .init(date: date, bySource: [.codex: .init(models: models)])
    }

    func testUnknownPriceDoesNotBecomeZeroInModelDetailAndCSVTotal() throws {
        let history = [detail(["private-model": .init(input: 100)])]
        let model = try XCTUnwrap(CodingModelDetail.summary(source: .codex, model: "private-model",
            liveDayModels: nil, persisted: history, todayKey: date, windowDays: 1))
        XCTAssertNil(model.pricedTotalUSD)
        XCTAssertNil(model.days.last?.pricedUSD)
        let values = UsageCSVExport.apiValueByDate(history)
        XCTAssertTrue(values.isEmpty)
        let csv = UsageCSVExport.makeCSV([.init(date: date, bySource: [.codex: 100], cost: 0)],
            apiValueByDate: values, modelHistory: history, plans: [.init(name: "Pro", monthlyFee: 20)], todayKey: date)
        let total = try XCTUnwrap(csv.split(separator: "\n").first { $0.hasPrefix("汇总,") })
        XCTAssertTrue(total.hasSuffix(",0.00,"), String(total))
        XCTAssertTrue(csv.contains("API 等价合计(USD) —"))
        XCTAssertTrue(csv.contains("回本倍数 —"))
        XCTAssertTrue(csv.contains("数据范围,已保存历史"))
        XCTAssertFalse(csv.contains("回本倍数 0.00"))
    }

    func testFreePricedModelIsKnownZeroNotUnknown() {
        let estimator = APICostEstimator(snapshots: [.init(model: "free", aliases: [],
            effectiveFrom: "2026-01-01", currency: "USD",
            perMillion: .init(newInput: 0, cachedInput: 0, cacheCreation: 0, output: 0, reasoningOutput: nil))])
        let summary = APIReferenceCostSummary(samples: [.init(model: "free", tokens: ModelTokenTally(input: 5).breakdown)],
            estimator: estimator, referenceDate: date)
        XCTAssertEqual(summary.pricedTotal, 0)
        XCTAssertTrue(summary.isFullyPriced)
        let csv = UsageCSVExport.makeCSV([.init(date: date, bySource: [.codex: 5], cost: 0)],
            apiValueByDate: [date: 0], todayKey: date)
        XCTAssertTrue(csv.contains("汇总,0,5,0,0,0,0,0,0,5,0,0.00,0.00"))
    }

    func testAllMissingPriceWeekHasNoRoiWhileMixedWeekIsALowerBound() throws {
        let unknown = [detail(["private-model": .init(input: 100)], date: "2026-09-22")]
        let curve = SubscriptionROICurve.weeklyPoints(participants: [.codex], monthlyFeeUSD: 20,
            persisted: unknown, today: DateUtil.date(from: "2026-09-28")!, weeks: 1)
        XCTAssertNil(curve.last?.multiple)
        XCTAssertNil(curve.last?.pricedValueUSD)
        let mixed = [detail(["private-model": .init(input: 100), "gpt-5.4": .init(input: 100)], date: "2026-09-22")]
        let point = try XCTUnwrap(SubscriptionROICurve.weeklyPoints(participants: [.codex], monthlyFeeUSD: 20,
            persisted: mixed, today: DateUtil.date(from: "2026-09-28")!, weeks: 1).last)
        XCTAssertTrue(point.isPartial)
        XCTAssertNotNil(point.multiple)
        let value = SubscriptionValueSummary(monthlyFeeUSD: 20, days: 7, apiValueUSD: point.apiValueUSD,
            apiValueKnown: point.apiValueKnown, priceCoverage: point.priceCoverage)
        XCTAssertTrue(value.multipleLabel.hasPrefix("至少 "))
        XCTAssertTrue(value.detailText.contains("不能据此判断"))
        XCTAssertFalse(value.detailText.contains("低于 1 倍表示"))
    }

    func testUnknownCurrentPriceCannotCreateFalseMinusOneHundredPercent() {
        let known = APIReferenceCostSummary(samples: [.init(model: "gpt-5.4", tokens: ModelTokenTally(input: 100).breakdown)],
            estimator: APIReferencePricingCatalog.estimator, referenceDate: date,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
        let unknown = APIReferenceCostSummary(samples: [.init(model: "private-model", tokens: ModelTokenTally(input: 100).breakdown)],
            estimator: APIReferencePricingCatalog.estimator, referenceDate: date)
        XCTAssertNil(unknown.pricedTotal)
        XCTAssertNil(unknown.changeCompared(to: known))
    }

    func testMissingCurrencyConversionDoesNotClaimFullPriceCoverage() {
        let estimator = APICostEstimator(snapshots: ["USD", "EUR"].map { currency in
            .init(model: currency, aliases: [], effectiveFrom: "2026-01-01", currency: currency,
                  perMillion: .init(newInput: 1, cachedInput: 1, cacheCreation: 1, output: 1, reasoningOutput: nil))
        })
        let summary = APIReferenceCostSummary(samples: ["USD", "EUR"].map {
            .init(model: $0, tokens: ModelTokenTally(input: 1_000_000).breakdown)
        }, estimator: estimator, referenceDate: date)
        XCTAssertEqual(summary.pricedTotal, 1)
        XCTAssertEqual(summary.coverage, 0.5)
        XCTAssertFalse(summary.isFullyPriced)
        XCTAssertNil(summary.changeCompared(to: summary))
        XCTAssertEqual(summary.unpricedModels, ["EUR"])
    }
}
