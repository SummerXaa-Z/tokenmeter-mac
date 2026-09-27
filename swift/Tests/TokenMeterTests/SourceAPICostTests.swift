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

    // MARK: - 周|近7天|月 窗口切换（与来源页历史环比卡同口径）

    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2   // 周一起始，与 zh-CN 本地周一致
        return c
    }

    private func summary(
        persisted: [ModelUsageDay], live: [String: [String: ModelTokenTally]]? = nil,
        period: PeriodCompare.Period, todayKey: String
    ) -> APIReferenceCostSummary? {
        SourceAPICost.summary(
            source: .kimi, liveDayModels: live, period: period,
            persisted: persisted, todayKey: todayKey, calendar: calendar)
    }

    // 2026-09-24 是周四：本周 = 09-21..24，近 7 天 = 09-18..24
    func testWeekWindowCutsAtCalendarWeekStart() throws {
        let days = [
            day("2026-09-19", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            day("2026-09-24", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ]
        let week = try XCTUnwrap(summary(persisted: days, period: .week, todayKey: "2026-09-24"))
        XCTAssertEqual(week.total, 2.44, accuracy: 0.001)   // 只含本周四那天
        let rolling = try XCTUnwrap(summary(persisted: days, period: .rolling7, todayKey: "2026-09-24"))
        XCTAssertEqual(rolling.total, 4.88, accuracy: 0.001) // 上周六也进滚动窗口
    }

    func testMonthWindowStartsAtFirstOfMonth() throws {
        let days = [
            day("2026-09-05", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            day("2026-09-24", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ]
        let month = try XCTUnwrap(summary(persisted: days, period: .month, todayKey: "2026-09-24"))
        XCTAssertEqual(month.total, 4.88, accuracy: 0.001)   // 1 号起整个本月都算
        let week = try XCTUnwrap(summary(persisted: days, period: .week, todayKey: "2026-09-24"))
        XCTAssertEqual(week.total, 2.44, accuracy: 0.001)    // 9/5 在本周之外
    }

    func testMonthMergesLiveAndPersistedDays() throws {
        let result = try XCTUnwrap(summary(
            persisted: [
                day("2026-09-05", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            ],
            live: ["2026-09-23": ["kimi-k2.6": .init(output: 1_000_000)]],
            period: .month, todayKey: "2026-09-24"))
        XCTAssertEqual(result.total, 4.88, accuracy: 0.001)
        XCTAssertEqual(result.totalTokens, 2_000_000)
    }

    func testEmptyPeriodShowsNilSummaryButCardStaysVisible() {
        // 本周还没用过（明细都在上周/更早）：当前档无汇总，但整卡不该消失
        let days = [
            day("2026-09-13", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ]
        XCTAssertNil(summary(persisted: days, period: .week, todayKey: "2026-09-24"))
        XCTAssertTrue(SourceAPICost.everUsed(source: .kimi, liveDayModels: nil, persisted: days))
        XCTAssertFalse(SourceAPICost.everUsed(source: .kimi, liveDayModels: nil, persisted: [
            day("2026-09-13", source: .kimi, [:]),
        ]))
    }

    // MARK: - 上期基期（环比徽标的基期金额）

    func testPriorSummaryWeekUsesPreviousWeek() throws {
        // 今天 09-24 周四：上期 = 上周 09-14..20；本周的 9M 不混入
        let days = [
            day("2026-09-16", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            day("2026-09-23", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
        ]
        let prior = try XCTUnwrap(SourceAPICost.priorSummary(
            source: .kimi, liveDayModels: nil, period: .week,
            persisted: days, todayKey: "2026-09-24", calendar: calendar))
        XCTAssertEqual(prior.total, 2.44, accuracy: 0.001)
        XCTAssertEqual(prior.totalTokens, 1_000_000)
    }

    func testPriorSummaryRolling7CoversPriorSevenDays() throws {
        // 今天 09-24：近 7 天的前一期 = 09-11..17；09-13 在内、09-19（本期）不在
        let days = [
            day("2026-09-13", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            day("2026-09-19", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
        ]
        let prior = try XCTUnwrap(SourceAPICost.priorSummary(
            source: .kimi, liveDayModels: nil, period: .rolling7,
            persisted: days, todayKey: "2026-09-24", calendar: calendar))
        XCTAssertEqual(prior.total, 2.44, accuracy: 0.001)
    }

    func testPriorSummaryMonthUsesPreviousMonth() throws {
        // 今天 09-24：上期 = 上月整月（08-01..31）；9/2 属本月不混入
        let days = [
            day("2026-08-31", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            day("2026-09-02", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
        ]
        let prior = try XCTUnwrap(SourceAPICost.priorSummary(
            source: .kimi, liveDayModels: nil, period: .month,
            persisted: days, todayKey: "2026-09-24", calendar: calendar))
        XCTAssertEqual(prior.total, 2.44, accuracy: 0.001)
    }

    // MARK: - 逐日金额（来源页 7 天趋势悬停）

    func testDailyValuesPriceEachDayAndSkipUnpricedDays() {
        // 09-24 旧价 $2.44、09-26 新价 $4；缺价日不建条目
        let values = SourceAPICost.dailyValues(
            source: .kimi, liveDayModels: nil,
            persisted: [
                day("2026-09-24", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
                day("2026-09-26", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
                day("2026-09-25", source: .kimi, ["mystery-model": .init(output: 1_000_000)]),
                // 窗口外
                day("2026-09-19", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
            ],
            todayKey: "2026-09-27", calendar: calendar)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values["2026-09-24"] ?? 0, 2.44, accuracy: 0.001)
        XCTAssertEqual(values["2026-09-26"] ?? 0, 4.0, accuracy: 0.001)
        XCTAssertNil(values["2026-09-25"])
    }

    // MARK: - 订阅回本（归属来源的月费折算）

    private func subscriptionValue(
        persisted: [ModelUsageDay], plans: [SubscriptionPlan],
        period: PeriodCompare.Period = .week,
        todayKey: String = "2026-09-27"
    ) -> SubscriptionValueSummary? {
        SourceAPICost.subscriptionValue(
            source: .kimi, liveDayModels: nil, period: period, plans: plans,
            persisted: persisted, todayKey: todayKey, calendar: calendar)
    }

    func testSubscriptionValueProratesTaggedPlanOverClampedDays() throws {
        // 今天 09-27 周日：本周 = 09-21..27；明细 09-25 起 → 只摊 3 天，
        // 不拿没明细的 09-21..24 摊订阅费
        let value = try XCTUnwrap(subscriptionValue(
            persisted: [
                day("2026-09-25", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
                day("2026-09-26", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            ],
            plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY", source: .kimi)]))
        XCTAssertEqual(value.monthlyFeeUSD, 20, accuracy: 0.001)
        XCTAssertEqual(value.days, 3)
        XCTAssertEqual(value.apiValueUSD, 8, accuracy: 0.001)
        XCTAssertEqual(value.proratedFeeUSD, 20 * 12.0 / 365 * 3, accuracy: 0.001)
        XCTAssertEqual(value.multiple ?? 0, 8 / (20 * 12.0 / 365 * 3), accuracy: 0.001)
        XCTAssertEqual(SubscriptionValueSummary.multipleText(value.multiple ?? 0), "约 4.1 倍")
        XCTAssertTrue(value.detailText.contains("按 3 天折算"))
    }

    func testSubscriptionValueUsesFullWindowWhenCoveragePredatesIt() throws {
        // 明细早于本周起点：整周 7 天都摊
        let value = try XCTUnwrap(subscriptionValue(
            persisted: [
                day("2026-09-19", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
                day("2026-09-26", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            ],
            plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY", source: .kimi)]))
        XCTAssertEqual(value.days, 7)
        XCTAssertEqual(value.proratedFeeUSD, 20 * 12.0 / 365 * 7, accuracy: 0.001)
        // 本周金额只含 09-26（09-19 在上周）
        XCTAssertEqual(value.apiValueUSD, 4, accuracy: 0.001)
    }

    func testSubscriptionValueNilCases() {
        let days = [
            day("2026-09-25", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ]
        // 未归属 / 归属别的来源的订阅：该来源页不显示回本
        XCTAssertNil(subscriptionValue(persisted: days, plans: []))
        XCTAssertNil(subscriptionValue(persisted: days, plans: [
            SubscriptionPlan(name: "Claude Max", monthlyFee: 100),
        ]))
        XCTAssertNil(subscriptionValue(persisted: days, plans: [
            SubscriptionPlan(name: "Claude Max", monthlyFee: 100, source: .claude),
        ]))
        // 归属了订阅但本期没有明细（都在上周）：无金额可言
        XCTAssertNil(subscriptionValue(
            persisted: [
                day("2026-09-16", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            ],
            plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY", source: .kimi)]))
    }

    func testSubscriptionValueMultipleTextThreshold() {
        XCTAssertEqual(SubscriptionValueSummary.multipleText(12.34), "约 12 倍")
        XCTAssertEqual(SubscriptionValueSummary.multipleText(9.96), "约 10.0 倍")
        XCTAssertEqual(SubscriptionValueSummary.multipleText(0.7), "约 0.7 倍")
    }
}
