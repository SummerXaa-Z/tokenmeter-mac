import XCTest
@testable import TokenMeter

final class CodingModelDetailTests: XCTestCase {
    private func modelDay(
        _ date: String, source: HistorySource, model: String,
        _ tally: ModelTokenTally
    ) -> ModelUsageDay {
        ModelUsageDay(date: date, bySource: [
            source: SourceDayDetail(models: [model: tally]),
        ])
    }

    private func day(
        _ summary: CodingModelDetail.Summary, _ date: String
    ) -> CodingModelDetail.DayValue? {
        summary.days.first { $0.date == date }
    }

    func testLiveOverridesSameDayAndIgnoresOtherModels() throws {
        // 留存 9/22 opus 1M(同天还挂着 kimi 的模型,不该计入)+ 9/20、9/10
        // 各 1M;实时 9/22 覆盖为 3M、9/20 只有别的模型 → 该天清零
        let persisted = [
            modelDay("2026-09-22", source: .claude, model: "opus-5-5",
                     .init(output: 1_000_000)),
            ModelUsageDay(date: "2026-09-22", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 5_000_000)]),
            ]),
            modelDay("2026-09-20", source: .claude, model: "opus-5-5",
                     .init(output: 1_000_000)),
            modelDay("2026-09-10", source: .claude, model: "opus-5-5",
                     .init(output: 1_000_000)),
        ]
        let live: [String: [String: ModelTokenTally]] = [
            "2026-09-22": ["opus-5-5": .init(output: 3_000_000)],
            "2026-09-20": ["sonnet-4.9": .init(output: 1_000_000)],
        ]
        let summary = try XCTUnwrap(CodingModelDetail.summary(
            source: .claude, model: "opus-5-5",
            liveDayModels: live, persisted: persisted,
            todayKey: "2026-09-28"))
        // 滚动 30 天(含今天),升序、整窗口补零
        XCTAssertEqual(summary.days.count, 30)
        XCTAssertEqual(summary.days.first?.date, "2026-08-30")
        XCTAssertEqual(summary.days.last?.date, "2026-09-28")
        // 9/22 实时覆盖:3M 输出 × $20/M(opus-5.5 当日起价)= $60
        let overridden = try XCTUnwrap(day(summary, "2026-09-22"))
        XCTAssertEqual(overridden.tokens, 3_000_000)
        XCTAssertEqual(overridden.usd, 60.0, accuracy: 0.001)
        // 9/20 实时确认该模型缺席:清掉留存旧值
        let cleared = try XCTUnwrap(day(summary, "2026-09-20"))
        XCTAssertEqual(cleared.tokens, 0)
        XCTAssertEqual(cleared.usd, 0)
        // 9/10 价格未生效(opus-5.5 自 9/22 起价):tokens 计入、金额不计
        let early = try XCTUnwrap(day(summary, "2026-09-10"))
        XCTAssertEqual(early.tokens, 1_000_000)
        XCTAssertEqual(early.usd, 0)
        XCTAssertEqual(summary.tally.total, 4_000_000)
        XCTAssertEqual(summary.coverage ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(summary.totalUSD, 60.0, accuracy: 0.001)
    }

    func testWindowIsRollingAndDropsOlderDays() throws {
        // 40 天连续 1M 输出:窗口只留最近 30 天;9/25 起 kimi-k2.6 调价
        // $2.44 → $4 → 26×2.44 + 4×4 = $79.44
        let calendar = Calendar.current
        let base = DateUtil.date(from: "2026-09-28")!
        let persisted = (0..<40).compactMap { offset -> ModelUsageDay? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: base)
            else { return nil }
            return modelDay(DateUtil.key(date), source: .kimi, model: "kimi-k2.6",
                            .init(output: 1_000_000))
        }
        let summary = try XCTUnwrap(CodingModelDetail.summary(
            source: .kimi, model: "kimi-k2.6",
            liveDayModels: nil, persisted: persisted,
            todayKey: "2026-09-28"))
        XCTAssertEqual(summary.days.first?.date, "2026-08-30")
        XCTAssertEqual(summary.tally.total, 30_000_000)
        XCTAssertEqual(summary.totalUSD, 79.44, accuracy: 0.001)
        XCTAssertEqual(summary.coverage ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.activeDays, 30)
    }

    func testWindowDaysParameterScopesRollingWindow() throws {
        // 95 天连续 1M 输出:windowDays 7 与 90 分别取最近 7/90 天
        let calendar = Calendar.current
        let base = DateUtil.date(from: "2026-09-28")!
        let persisted = (0..<95).compactMap { offset -> ModelUsageDay? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: base)
            else { return nil }
            return modelDay(DateUtil.key(date), source: .kimi, model: "kimi-k2.6",
                            .init(output: 1_000_000))
        }
        let week = try XCTUnwrap(CodingModelDetail.summary(
            source: .kimi, model: "kimi-k2.6",
            liveDayModels: nil, persisted: persisted,
            todayKey: "2026-09-28", windowDays: 7))
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.first?.date, "2026-09-22")
        XCTAssertEqual(week.days.last?.date, "2026-09-28")
        XCTAssertEqual(week.activeDays, 7)
        // 9/22–9/24 调价前 $2.44,9/25–9/28 $4.00 → 3×2.44 + 4×4
        XCTAssertEqual(week.totalUSD, 23.32, accuracy: 0.001)

        let quarter = try XCTUnwrap(CodingModelDetail.summary(
            source: .kimi, model: "kimi-k2.6",
            liveDayModels: nil, persisted: persisted,
            todayKey: "2026-09-28", windowDays: 90))
        XCTAssertEqual(quarter.days.count, 90)
        XCTAssertEqual(quarter.days.first?.date, "2026-07-01")
        XCTAssertEqual(quarter.tally.total, 90_000_000)
        // 7/1–9/24 共 86 天 × $2.44 + 4 天 × $4.00
        XCTAssertEqual(quarter.totalUSD, 225.84, accuracy: 0.001)
        XCTAssertEqual(quarter.coverage ?? 0, 1.0, accuracy: 0.0001)

        // 非法窗口直接判无数据
        XCTAssertNil(CodingModelDetail.summary(
            source: .kimi, model: "kimi-k2.6",
            liveDayModels: nil, persisted: persisted,
            todayKey: "2026-09-28", windowDays: 0))
    }

    func testWeeklyBucketsFoldDaysIntoMondayAnchoredWeeks() throws {
        // 9/7、9/14、9/21 为周一;9/5 周六归到 8/31 那周(首周不足整周)
        let days = [
            CodingModelDetail.DayValue(date: "2026-09-05", usd: 1.0,
                                       tally: .init(output: 100)),
            CodingModelDetail.DayValue(date: "2026-09-07", usd: 2.0,
                                       tally: .init(output: 200)),
            CodingModelDetail.DayValue(date: "2026-09-08", usd: 3.0,
                                       tally: .init(input: 50)),
            CodingModelDetail.DayValue(date: "2026-09-20", usd: 4.0,
                                       tally: .init(output: 400)),
            CodingModelDetail.DayValue(date: "2026-09-21", usd: 6.0,
                                       tally: .init(output: 600)),
        ]
        let weeks = CodingModelDetail.weeklyBuckets(from: days)
        XCTAssertEqual(weeks.map(\.weekStart),
                       ["2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21"])
        XCTAssertEqual(weeks.map(\.usd), [1.0, 5.0, 4.0, 6.0])
        // 同周 Token 合并、跨天分量保留
        XCTAssertEqual(weeks[1].tally, .init(input: 50, output: 200))
        XCTAssertEqual(weeks.map(\.tokens), [100, 250, 400, 600])
        XCTAssertEqual(CodingModelDetail.weeklyBuckets(from: []), [])
    }

    func testUnpricedModelCountsTokensWithoutAmount() throws {
        // 缺价模型:快照非空、tokens/活跃天如实,金额恒 0、覆盖率 0
        let summary = try XCTUnwrap(CodingModelDetail.summary(
            source: .kimi, model: "mystery-model",
            liveDayModels: ["2026-09-26": ["mystery-model": .init(output: 800_000)]],
            persisted: [], todayKey: "2026-09-28"))
        XCTAssertEqual(summary.tally.total, 800_000)
        XCTAssertEqual(summary.activeDays, 1)
        XCTAssertEqual(summary.totalUSD, 0)
        XCTAssertEqual(summary.coverage ?? -1, 0)
    }

    func testNilWhenWindowHasNoUsage() {
        XCTAssertNil(CodingModelDetail.summary(
            source: .claude, model: "opus-5-5",
            liveDayModels: nil, persisted: [], todayKey: "2026-09-28"))
        // 窗口外的留存不算
        XCTAssertNil(CodingModelDetail.summary(
            source: .claude, model: "opus-5-5",
            liveDayModels: nil,
            persisted: [modelDay("2026-01-05", source: .claude, model: "opus-5-5",
                                 .init(output: 1_000_000))],
            todayKey: "2026-09-28"))
    }
}
