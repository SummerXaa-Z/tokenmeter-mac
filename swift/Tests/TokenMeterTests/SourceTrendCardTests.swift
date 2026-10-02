import XCTest
@testable import TokenMeter

// 来源页 7|30 天趋势卡：30 天档的数据装配（留存 + 实时覆盖 + 补零时间轴）
// 与各来源分量折叠口径。
final class SourceTrendCardTests: XCTestCase {
    private func modelDay(
        _ date: String, source: HistorySource,
        _ models: [String: ModelTokenTally]
    ) -> ModelUsageDay {
        ModelUsageDay(date: date, bySource: [source: SourceDayDetail(models: models)])
    }

    private func monthDays(
        persisted: [ModelUsageDay], live: [String: [String: ModelTokenTally]]? = nil,
        source: HistorySource = .kimi
    ) -> [SourceTrendCard.Day] {
        SourceTrendCard.monthDays(
            source: source, liveDayModels: live, persisted: persisted,
            todayKey: "2026-09-27")
    }

    func testMonthDaysPadsToFullWindowAndOverridesWithLive() {
        let days = monthDays(
            persisted: [
                modelDay("2026-09-26", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
                // 窗口外(30 天 = 08-29..09-27)
                modelDay("2026-08-20", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
                // 非本来源的明细不计
                modelDay("2026-09-25", source: .codex, ["gpt-5.5": .init(output: 9_000_000)]),
            ],
            live: ["2026-09-26": ["kimi-k2.6": .init(output: 2_000_000)]])
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first?.date, "2026-08-29")
        XCTAssertEqual(days.last?.date, "2026-09-27")
        let liveDay = days.first { $0.date == "2026-09-26" }
        XCTAssertEqual(liveDay?.parts.first { $0.name == "输出" }?.value, 2_000_000)
        // 其余天补零:分量结构仍完整(图例稳定)
        let zero = days.first { $0.date == "2026-09-10" }
        XCTAssertEqual(zero?.parts.count, 4)
        XCTAssertTrue(zero?.parts.allSatisfy { $0.value == 0 } ?? false)
    }

    func testMonthDaysLiveEmptyClearsPersistedDay() {
        // 实时确认当天无明细:清掉留存旧值,不留幽灵分量
        let days = monthDays(
            persisted: [
                modelDay("2026-09-25", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            ],
            live: ["2026-09-25": [:]])
        let cleared = days.first { $0.date == "2026-09-25" }
        XCTAssertTrue(cleared?.parts.allSatisfy { $0.value == 0 } ?? false)
    }

    func testPartsFoldPerSourceConvention() {
        let tally = ModelTokenTally(
            input: 1, cached: 2, cacheWrite: 3, output: 4, reasoning: 5)
        // Codex:三段,输出并入 reasoning
        XCTAssertEqual(SourceTrendCard.parts(.codex, of: tally).map(\.name),
                       ["缓存输入", "新输入", "输出"])
        XCTAssertEqual(
            SourceTrendCard.parts(.codex, of: tally).last?.value, 9)
        // Gemini/Qwen:推理单列
        XCTAssertEqual(SourceTrendCard.parts(.gemini, of: tally).map(\.name),
                       ["缓存读取", "新输入", "输出", "推理"])
        XCTAssertEqual(
            SourceTrendCard.parts(.qwen, of: tally).last?.value, 5)
        // Claude/Kimi/OpenCode/Copilot:四段,推理并入输出
        XCTAssertEqual(SourceTrendCard.parts(.claude, of: tally).map(\.name),
                       ["缓存读取", "缓存写入", "新输入", "输出"])
        XCTAssertEqual(
            SourceTrendCard.parts(.opencode, of: tally).last?.value, 9)
        // 平台账户/订阅聚合无按天明细页
        XCTAssertTrue(SourceTrendCard.parts(.cursor, of: tally).isEmpty)
    }

    func testEmptyDetectionForTrendAndHourCharts() {
        // 7|30 天趋势:整窗全零(或无桶)才空,任一天有量即非空
        func zeroDay(_ date: String, tokens: Int) -> SourceTrendCard.Day {
            .init(date: date, parts: [("缓存读取", tokens, Theme.hit)])
        }
        XCTAssertTrue(SourceTrendCard.isEmpty([]))
        XCTAssertTrue(SourceTrendCard.isEmpty([zeroDay("2026-10-01", tokens: 0)]))
        XCTAssertFalse(SourceTrendCard.isEmpty([zeroDay("2026-10-02", tokens: 5)]))
        // 24 小时分时:全天零(或无柱)即空,任一钟点有量即非空
        func bar(_ tokens: Int) -> SourceHourChart.Bar {
            .init(hour: 9, tokens: tokens)
        }
        XCTAssertTrue(SourceHourChart.isEmpty([]))
        XCTAssertTrue(SourceHourChart.isEmpty([bar(0), bar(0)]))
        XCTAssertFalse(SourceHourChart.isEmpty([bar(0), bar(3)]))
        // 总览趋势:无桶或整窗全零为空(时间轴补零后 isEmpty 不够);
        // 有量桶存在即非空,图例隐藏由调用方在全量口径上判,不在此函数
        func point(_ tokens: Int) -> OverviewSnapshot.TrendPoint {
            .init(date: "2026-10-03", label: "10/3", hour: nil, source: .claude, tokens: tokens)
        }
        XCTAssertTrue(TrendSeriesFilter.isAllZero([]))
        XCTAssertTrue(TrendSeriesFilter.isAllZero([point(0), point(0)]))
        XCTAssertFalse(TrendSeriesFilter.isAllZero([point(0), point(7)]))
    }
}
