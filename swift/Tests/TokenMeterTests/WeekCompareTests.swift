import XCTest
@testable import TokenMeter

final class WeekCompareTests: XCTestCase {
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

    // 2026-09-21 是周一,25 日(周五)在同一个日历周
    private let thisWeek = ["2026-09-21", "2026-09-25"]
    private let lastWeek = ["2026-09-14", "2026-09-20"]

    private func compare(_ days: [HistoryStore.DayPoint]) -> (
        thisWeek: [HistorySource: Int], lastWeek: [HistorySource: Int]
    ) {
        WeekCompare.bySource(
            days,
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!,
            calendar: calendar
        )
    }

    func testSplitsCalendarWeeksPerSource() {
        let result = compare([
            day("2026-09-25", bySource: [.claude: 100, .codex: 7]),
            day("2026-09-21", bySource: [.claude: 50]),
            day("2026-09-20", bySource: [.claude: 30, .codex: 3]),
        ])
        XCTAssertEqual(result.thisWeek[.claude], 150)
        XCTAssertEqual(result.thisWeek[.codex], 7)
        XCTAssertEqual(result.lastWeek[.claude], 30)
        XCTAssertEqual(result.lastWeek[.codex], 3)
    }

    func testExcludesNonParticipantsAndPlatformAndOtherWeeks() {
        let result = compare([
            day("2026-09-25", bySource: [.claude: 10, .deepseek: 999, .kimi: 888]),
            day("2026-09-13", bySource: [.claude: 70]),   // 上上周
        ])
        XCTAssertEqual(result.thisWeek, [.claude: 10])
        XCTAssertTrue(result.lastWeek.isEmpty)
    }

    func testRowsOnlyKeepSourcesWithAnyUsageSortedByMaxSide() {
        let rows = WeekCompare.rows(
            thisWeek: [.claude: 100, .codex: 5, .kimi: 0],
            lastWeek: [.codex: 300, .gemini: 0]
        )
        XCTAssertEqual(rows, [
            .init(source: .codex, this: 5, last: 300),    // max 300
            .init(source: .claude, this: 100, last: 0),   // max 100
        ])
    }

    func testChangePercentAndNoBaseline() {
        XCTAssertEqual(WeekCompare.change(this: 120, last: 100)!, 20, accuracy: 0.001)
        XCTAssertEqual(WeekCompare.change(this: 50, last: 200)!, -75, accuracy: 0.001)
        XCTAssertNil(WeekCompare.change(this: 50, last: 0))
        XCTAssertNil(WeekCompare.change(this: 0, last: 0))
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
