import XCTest
@testable import TokenMeter

final class SubscriptionROICurveTests: XCTestCase {
    private func modelDay(
        _ date: String, source: HistorySource = .kimi,
        _ models: [String: ModelTokenTally] = ["kimi-k2.6": .init(output: 1_000_000)]
    ) -> ModelUsageDay {
        ModelUsageDay(date: date, bySource: [source: SourceDayDetail(models: models)])
    }

    private func points(
        _ persisted: [ModelUsageDay],
        monthlyFeeUSD: Double = 120,
        weeks: Int = 13,
        today: String = "2026-09-30"   // 周三
    ) -> [SubscriptionROICurve.WeekPoint] {
        SubscriptionROICurve.weeklyPoints(
            participants: [.kimi, .opencode],
            monthlyFeeUSD: monthlyFeeUSD,
            persisted: persisted,
            today: DateUtil.date(from: today)!,
            weeks: weeks)
    }

    func testOnlyCompleteWeeksOldestFirst() {
        // 留存从 26 周前开始:13 个完整周、升序,本周(9/28 起,含今天)不计
        let calendar = Calendar.current
        let base = DateUtil.date(from: "2026-09-30")!
        let persisted = (0..<180).compactMap { offset -> ModelUsageDay? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: base)
            else { return nil }
            return modelDay(DateUtil.key(date))
        }
        let all = points(persisted)
        XCTAssertEqual(all.count, 13)
        XCTAssertEqual(all.first?.weekOf, "2026-06-29")   // 13 周前的周一
        XCTAssertEqual(all.last?.weekOf, "2026-09-21")    // 上周一
        // 每周分母 = 7 天摊费
        let fee = 120.0 * 12 / 365 * 7
        XCTAssertEqual(all.first?.feeUSD ?? 0, fee, accuracy: 0.001)
    }

    func testApiValueSumsWithinWeekAndCoverageStartClampsFee() {
        // 留存起点 7/1(周三):6/29 那周只摊 7/1-7/5 五天,此前为零
        // (更早的完整周 feeUSD = 0 → multiple nil)
        let persisted = [
            modelDay("2026-07-01"),
            modelDay("2026-09-22"), modelDay("2026-09-24"),
        ]
        let all = points(persisted)
        let partial = all.first { $0.weekOf == "2026-06-29" }
        let partialFee = 120.0 * 12 / 365 * 5
        XCTAssertEqual(partial?.feeUSD ?? 0, partialFee, accuracy: 0.001)
        XCTAssertEqual(partial?.multiple ?? 0, 2.44 / partialFee, accuracy: 0.0001)
        // 窗口再往前一周(6/22)不在 13 周内,数组不含它
        XCTAssertFalse(all.contains { $0.weekOf == "2026-06-22" })
        // 上周(9/21-9/27)两天各 $2.44
        let last = all.last
        XCTAssertEqual(last?.apiValueUSD ?? 0, 2 * 2.44, accuracy: 0.001)
        XCTAssertEqual(last?.multiple ?? 0, 2 * 2.44 / (120.0 * 12 / 365 * 7), accuracy: 0.0001)
    }

    func testZeroUsageWeekMultipleIsZeroNotNil() {
        // 只有 7 月的留存:9 月的周金额为 0 但分母正常 → multiple = 0
        let all = points([modelDay("2026-07-01")])
        let last = all.last
        XCTAssertEqual(last?.apiValueUSD, 0)
        XCTAssertEqual(last?.multiple, 0)
    }

    func testFiltersParticipantsAndGuards() {
        // 非参与来源的明细不算覆盖起点
        XCTAssertTrue(points([modelDay("2026-07-01", source: .codex)]).isEmpty)
        // 无明细 / 零月费 / 无参与来源 → 空
        XCTAssertTrue(points([]).isEmpty)
        XCTAssertTrue(points([modelDay("2026-07-01")], monthlyFeeUSD: 0).isEmpty)
        XCTAssertTrue(SubscriptionROICurve.weeklyPoints(
            participants: [.deepseek], monthlyFeeUSD: 120,
            persisted: [modelDay("2026-07-01")]).isEmpty)
    }

    func testMultipleTextScalesWithMagnitude() {
        XCTAssertEqual(SubscriptionValueSummary.multipleText(2.34), "约 2.3 倍")
        XCTAssertEqual(SubscriptionValueSummary.multipleText(0.62), "约 0.6 倍")
        XCTAssertEqual(SubscriptionValueSummary.multipleText(12.4), "约 12 倍")
    }
}
