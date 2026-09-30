import XCTest
@testable import TokenMeter

final class WeeklyDigestTests: XCTestCase {
    private func day(
        _ date: String,
        bySource: [HistorySource: Int]
    ) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(date: date, bySource: bySource, cost: 0)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2   // 周一起始
        return c
    }

    // 2026-09-21 是周一;09-23 周三、09-24 周四、09-28 下一个周一
    private func date(_ day: String, _ time: String = "10:00") -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) \(time)")!
    }

    func testWeekKeyStableWithinIsoWeekAndDiffersAcross() {
        XCTAssertEqual(
            WeeklyDigest.weekKey(date("2026-09-21"), calendar: calendar),
            WeeklyDigest.weekKey(date("2026-09-27"), calendar: calendar))
        XCTAssertNotEqual(
            WeeklyDigest.weekKey(date("2026-09-21"), calendar: calendar),
            WeeklyDigest.weekKey(date("2026-09-28"), calendar: calendar))
    }

    func testIsDueOnlyMondayToWednesdayAfterNine() {
        XCTAssertTrue(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-21", "10:00"), calendar: calendar))
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-21", "08:59"), calendar: calendar))
        XCTAssertTrue(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-23", "09:00"), calendar: calendar))
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-24", "10:00"), calendar: calendar))
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-26", "10:00"), calendar: calendar))
        // 本周已发过(同 ISO 周键)不再发
        let sent = WeeklyDigest.weekKey(date("2026-09-21"), calendar: calendar)
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: sent, today: date("2026-09-22", "10:00"), calendar: calendar))
    }

    func testMessageComparesLastFullWeekToPriorWeek() {
        // 今天 09-28 周一:摘要应为上周(9/21-9/27) vs 上上周(9/14-9/20)。
        // modelDays 显式传空:金额段只认按天明细,没有就整段省略
        let message = WeeklyDigest.message([
            day("2026-09-25", bySource: [.claude: 300_000_000, .codex: 100_000_000]),
            day("2026-09-16", bySource: [.claude: 200_000_000]),
            day("2026-09-28", bySource: [.claude: 50_000_000]),   // 本周不计
            day("2026-09-20", bySource: [.deepseek: 9_999_999]),  // 平台不计
        ], participants: [.claude, .codex],
           modelDays: [],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(message?.title, "TokenMeter 上周用量摘要")
        XCTAssertEqual(message?.body, "合计 400M，环比 ↑ 100%；主力 Claude 75%")
    }

    func testMessageNilWhenLastWeekEmpty() {
        // 上周一条记录都没有:即使上上周有量也不打扰
        let message = WeeklyDigest.message([
            day("2026-09-16", bySource: [.claude: 200_000_000]),
        ], participants: [.claude], modelDays: [],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertNil(message)
    }

    func testMessageSingleSourceAndNoBaseline() {
        // 上上周无基期:不拼环比;单来源:说"全部来自"
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.codex: 2_000_000]),
        ], participants: [.claude, .codex], modelDays: [],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(message?.body, "合计 2M；全部来自 Codex")
    }

    // MARK: - API 等价金额

    // 金额段必附的价格新鲜度段;动态引用 observedAt,目录刷新后测试不漂移
    private var checkedAt: String {
        "，最近核对 \(APIReferencePricingCatalog.observedAt)"
    }

    private func modelDay(
        _ date: String, source: HistorySource,
        _ models: [String: ModelTokenTally]
    ) -> ModelUsageDay {
        ModelUsageDay(date: date, bySource: [source: SourceDayDetail(models: models)])
    }

    func testMessageAppendsAPIEquivalentAmountWithChange() {
        // kimi-k2.6 输出价 09-25 前后 $2.44/$4 每 M:上周 3M=$9.32,上上周 1M=$2.44
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 3_000_000]),
            day("2026-09-15", bySource: [.kimi: 1_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-22", source: .kimi, ["kimi-k2.6": .init(output: 3_000_000)]),
               modelDay("2026-09-15", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
           ],
           today: date("2026-09-28"), calendar: calendar)
        // 3M×2.44 = 7.32 → 环比 (7.32-2.44)/2.44 = 200%
        XCTAssertEqual(
            message?.body,
            "合计 3M，环比 ↑ 200%；全部来自 Kimi Code；API 等价 $7.32（环比 ↑ 200%）\(checkedAt)")
    }

    func testMessageAmountOmittedWithoutModelDetail() {
        // Token 历史在、按天模型明细不在(如 v3.12 之前的老数据):金额段省略
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 1_000_000]),
        ], participants: [.kimi], modelDays: [],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(message?.body, "合计 1M；全部来自 Kimi Code")
    }

    func testMessageAmountNotesCoverageForUnpricedModels() {
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 2_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-22", source: .kimi, [
                   "kimi-k2.6": .init(output: 1_000_000),
                   "mystery-model": .init(output: 1_000_000),
               ]),
           ],
           today: date("2026-09-28"), calendar: calendar)
        // 上上周无金额基期:不拼环比;缺价一半:覆盖 50%,低于阈值点名缺价模型
        XCTAssertEqual(
            message?.body,
            "合计 2M；全部来自 Kimi Code；API 等价 $2.44，价格覆盖 50%\(checkedAt)，缺价 mystery-model")
    }

    func testMessageAmountIgnoresDisabledSourcesAndCurrentWeek() {
        // 关闭的来源与本周的明细不进金额;只有上周启用来源的按天明细计价
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 1_000_000, .codex: 5_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-22", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
               modelDay("2026-09-22", source: .codex, ["gpt-5.5": .init(output: 9_999_999)]),
               modelDay("2026-09-28", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
           ],
           today: date("2026-09-28"), calendar: calendar)
        // 未启用的 Codex 与本周(09-28)的明细都不进金额,金额段只算 Kimi $2.44
        XCTAssertEqual(
            message?.body,
            "合计 1M；全部来自 Kimi Code；API 等价 $2.44\(checkedAt)")
    }

    func testMessageCapsUnpricedModelNamesAtTwo() {
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 4_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-22", source: .kimi, [
                   "kimi-k2.6": .init(output: 1_000_000),
                   "mystery-a": .init(output: 1_000_000),
                   "mystery-b": .init(output: 1_000_000),
                   "mystery-c": .init(output: 1_000_000),
               ]),
           ],
           today: date("2026-09-28"), calendar: calendar)
        // 覆盖 25%:点名前两个缺价模型,其余收进「等」,通知保持一行可读
        XCTAssertEqual(
            message?.body,
            "合计 4M；全部来自 Kimi Code；API 等价 $2.44，价格覆盖 25%\(checkedAt)，缺价 mystery-a、mystery-b 等")
    }

    func testMessageOmitsUnpricedNamesAboveCoverageThreshold() {
        // 覆盖 96%(≥95%):显示覆盖率与核对日期,但不点名缺价模型
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 25_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-22", source: .kimi, [
                   "kimi-k2.6": .init(output: 24_000_000),
                   "mystery-model": .init(output: 1_000_000),
               ]),
           ],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(
            message?.body,
            "合计 25M；全部来自 Kimi Code；API 等价 $58.56，价格覆盖 96%\(checkedAt)")
    }

    // MARK: - 订阅回本

    func testMessageAppendsSubscriptionMultipleWithClampedDays() {
        // 明细从上周二(09-22)才有 → 只摊 09-22..27 共 6 天,不拿周一起摊。
        // ¥138/月 = $20,折算 20×12/365×6;金额 $7.32 → 约 1.9 倍
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 3_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-22", source: .kimi, ["kimi-k2.6": .init(output: 3_000_000)]),
           ],
           plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY")],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(
            message?.body,
            "合计 3M；全部来自 Kimi Code；API 等价 $7.32\(checkedAt)；订阅回本 约 1.9 倍")
    }

    func testMessageSubscriptionUsesFullWeekWhenCoveragePredatesIt() {
        // 明细早于上周(09-10) → 整周 7 天摊;多币种合计 $120 → 7.32/27.62 ≈ 0.3 倍
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 3_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-10", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
               modelDay("2026-09-22", source: .kimi, ["kimi-k2.6": .init(output: 3_000_000)]),
           ],
           plans: [
               SubscriptionPlan(name: "Claude Max", monthlyFee: 100),
               SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY"),
           ],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(
            message?.body,
            "合计 3M；全部来自 Kimi Code；API 等价 $7.32\(checkedAt)；订阅回本 约 0.3 倍")
    }

    func testMessageSubscriptionOmittedWithoutPositiveFee() {
        // 月费为 0 的订阅不计入:分母为 0,段省略(金额段保留)
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.kimi: 1_000_000]),
        ], participants: [.kimi],
           modelDays: [
               modelDay("2026-09-22", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
           ],
           plans: [SubscriptionPlan(name: "Free Tier", monthlyFee: 0)],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(
            message?.body,
            "合计 1M；全部来自 Kimi Code；API 等价 $2.44\(checkedAt)")
    }
}
