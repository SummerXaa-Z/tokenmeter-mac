import XCTest
@testable import TokenMeter

final class PeriodCompareTests: XCTestCase {
    private func day(
        _ date: String,
        bySource: [HistorySource: Int]
    ) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(date: date, bySource: bySource, cost: 0)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2   // 周一起始,与 zh-CN 本地周一致
        return c
    }

    // 2026-09-21 是周一,25 日(周五)同周;9/30 与 9/25 同月,8/31 上一月
    private func compare(
        _ days: [HistoryStore.DayPoint],
        period: PeriodCompare.Period
    ) -> (this: [HistorySource: Int], last: [HistorySource: Int]) {
        PeriodCompare.bySource(
            days,
            period: period,
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!,
            calendar: calendar
        )
    }

    func testWeekSplitsCalendarWeeksPerSource() {
        let result = compare([
            day("2026-09-25", bySource: [.claude: 100, .codex: 7]),
            day("2026-09-21", bySource: [.claude: 50]),
            day("2026-09-20", bySource: [.claude: 30, .codex: 3]),
        ], period: .week)
        XCTAssertEqual(result.this[.claude], 150)
        XCTAssertEqual(result.this[.codex], 7)
        XCTAssertEqual(result.last[.claude], 30)
        XCTAssertEqual(result.last[.codex], 3)
    }

    func testMonthSplitsCalendarMonthsPerSource() {
        let result = compare([
            day("2026-09-01", bySource: [.claude: 100]),
            day("2026-09-30", bySource: [.codex: 7]),
            day("2026-08-31", bySource: [.claude: 30, .codex: 3]),
            day("2026-07-31", bySource: [.claude: 999]),   // 上上月不计
        ], period: .month)
        XCTAssertEqual(result.this[.claude], 100)
        XCTAssertEqual(result.this[.codex], 7)
        XCTAssertEqual(result.last[.claude], 30)
        XCTAssertEqual(result.last[.codex], 3)
    }

    func testExcludesNonParticipantsAndPlatformAndOtherPeriods() {
        let result = compare([
            day("2026-09-25", bySource: [.claude: 10, .deepseek: 999, .kimi: 888]),
            day("2026-09-13", bySource: [.claude: 70]),   // 上上周
        ], period: .week)
        XCTAssertEqual(result.this, [.claude: 10])
        XCTAssertTrue(result.last.isEmpty)
    }

    func testRowsOnlyKeepSourcesWithAnyUsageSortedByMaxSide() {
        let rows = PeriodCompare.rows(
            this: [.claude: 100, .codex: 5, .kimi: 0],
            last: [.codex: 300, .gemini: 0]
        )
        XCTAssertEqual(rows, [
            .init(source: .codex, this: 5, last: 300),    // max 300
            .init(source: .claude, this: 100, last: 0),   // max 100
        ])
    }

    func testChangePercentAndNoBaseline() {
        XCTAssertEqual(PeriodCompare.change(this: 120, last: 100)!, 20, accuracy: 0.001)
        XCTAssertEqual(PeriodCompare.change(this: 50, last: 200)!, -75, accuracy: 0.001)
        XCTAssertNil(PeriodCompare.change(this: 50, last: 0))
        XCTAssertNil(PeriodCompare.change(this: 0, last: 0))
    }
}

final class TrendSeriesFilterTests: XCTestCase {
    private func point(
        _ source: HistorySource, _ label: String, _ tokens: Int
    ) -> OverviewSnapshot.TrendPoint {
        OverviewSnapshot.TrendPoint(
            date: label, label: label, hour: nil, source: source, tokens: tokens)
    }

    func testSeriesTotalsAggregateSortAndDropZero() {
        let totals = TrendSeriesFilter.seriesTotals([
            point(.claude, "9/24", 100),
            point(.codex, "9/24", 300),
            point(.claude, "9/25", 50),
            point(.kimi, "9/24", 0),
        ])
        XCTAssertEqual(totals.map(\.name), ["Codex", "Claude"])
        XCTAssertEqual(totals.map(\.total), [300, 150])
    }

    func testVisibleFiltersHiddenChartNames() {
        let points = [
            point(.claude, "9/24", 100),
            point(.codex, "9/24", 300),
            point(.qwen, "9/24", 10),
        ]
        let visible = TrendSeriesFilter.visible(points, hidden: ["Codex", "Qwen"])
        XCTAssertEqual(visible.map(\.source), [.claude])

        // 空隐藏集原样返回
        XCTAssertEqual(TrendSeriesFilter.visible(points, hidden: []).count, 3)
    }
}
