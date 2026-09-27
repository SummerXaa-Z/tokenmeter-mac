import Foundation
import XCTest
@testable import TokenMeter

// 来源页「近 7 天 API 等价」卡的汇总逻辑：按用量当日生效价计价、
// 实时明细覆盖留存同一天、窗口只取最近 7 天、缺价模型不计入金额。
final class SourceAPICostTests: XCTestCase {
    private let today = "2026-09-27"

    private func day(
        _ date: String, source: HistorySource,
        _ models: [String: ModelTokenTally]
    ) -> ModelUsageDay {
        ModelUsageDay(date: date, bySource: [source: SourceDayDetail(models: models)])
    }

    // kimi-k2.6 输出价：2026-09-25 前 $2.44/M，之后 $4/M
    private func summary(
        persisted: [ModelUsageDay], live: [String: [String: ModelTokenTally]]? = nil,
        source: HistorySource = .kimi, todayKey: String? = nil
    ) -> APIReferenceCostSummary? {
        SourceAPICost.summary(
            source: source, liveDayModels: live, persisted: persisted,
            todayKey: todayKey ?? today)
    }

    func testPricesFollowUsageDayNotReferenceDate() throws {
        let result = try XCTUnwrap(summary(persisted: [
            day("2026-09-24", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            day("2026-09-26", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ]))
        XCTAssertEqual(result.total, 6.44, accuracy: 0.001)
        XCTAssertEqual(result.coverage, 1)
        XCTAssertEqual(result.modelAmounts.count, 1)
        XCTAssertEqual(result.modelAmounts.first?.model, "kimi-k2.6")
        XCTAssertEqual(result.unpricedModels, [])
    }

    func testUnpricedModelExcludedFromTotalButReported() throws {
        let result = try XCTUnwrap(summary(persisted: [
            day("2026-09-24", source: .kimi, [
                "kimi-k2.6": .init(output: 1_000_000),
                "mystery-model": .init(output: 1_000_000),
            ]),
        ]))
        XCTAssertEqual(result.total, 2.44, accuracy: 0.001)
        XCTAssertEqual(result.coverage, 0.5)
        XCTAssertEqual(result.unpricedModels, ["mystery-model"])
    }

    func testLiveDayModelsOverridePersistedSameDay() throws {
        let result = try XCTUnwrap(summary(
            persisted: [
                day("2026-09-26", source: .kimi, ["kimi-k2.6": .init(output: 2_000_000)]),
            ],
            live: ["2026-09-26": ["kimi-k2.6": .init(output: 1_000_000)]]))
        XCTAssertEqual(result.total, 4.0, accuracy: 0.001)
        XCTAssertEqual(result.totalTokens, 1_000_000)
    }

    func testWindowKeepsOnlyLastSevenDays() throws {
        let result = try XCTUnwrap(summary(persisted: [
            // 窗口外（09-27 往前 7 天 = 09-21..09-27）与未来日都不计入
            day("2026-09-13", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
            day("2026-09-25", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ], live: ["2026-09-28": ["kimi-k2.6": .init(output: 9_000_000)]]))
        XCTAssertEqual(result.total, 4.0, accuracy: 0.001)
    }

    func testNilWhenSourceHasNoWindowDetail() {
        XCTAssertNil(summary(persisted: []))
        // 只有别的来源的明细时，本来源卡隐藏
        XCTAssertNil(summary(persisted: [
            day("2026-09-25", source: .codex, ["gpt-5.5": .init(output: 1_000_000)]),
        ], source: .kimi))
    }

    func testUsageBeforeFirstSnapshotPricedAtFirstSnapshot() throws {
        // 首个价格快照 2026-08-12；更早的用量按这一天的价格参考而不是缺价
        let result = try XCTUnwrap(summary(
            persisted: [
                day("2026-08-10", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            ],
            todayKey: "2026-08-14"))
        XCTAssertEqual(result.total, 2.44, accuracy: 0.001)
        XCTAssertEqual(result.unpricedModels, [])
    }

    func testCNYOfficialPriceConvertedToUSD() throws {
        let result = try XCTUnwrap(summary(persisted: [
            day("2026-09-26", source: .opencode,
                ["doubao-seed-evolving": .init(output: 1_000_000)]),
        ], source: .opencode))
        XCTAssertEqual(result.currency, "USD")
        XCTAssertEqual(result.amounts.first?.currency, "CNY")
        XCTAssertEqual(result.amounts.first?.total ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(result.total, 30 / 6.9, accuracy: 0.001)
    }
}
