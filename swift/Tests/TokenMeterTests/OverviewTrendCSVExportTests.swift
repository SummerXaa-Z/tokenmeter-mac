import XCTest
@testable import TokenMeter

// 总览趋势卡导出：逐桶一行、来源分列、列序与图例一致、小时档无金额列。
final class OverviewTrendCSVExportTests: XCTestCase {
    private func parseRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
    }

    private func point(
        _ date: String, label: String, source: HistorySource, tokens: Int,
        hour: Int? = nil
    ) -> OverviewSnapshot.TrendPoint {
        .init(date: date, label: label, hour: hour, source: source, tokens: tokens)
    }

    func testDayModeColumnsFollowLegendOrderAndCarryAmounts() {
        // 合计降序:Claude 列在 Codex 前;金额列与悬停同口径(无金额留空)
        let csv = OverviewTrendCSVExport.makeCSV(
            trend: [
                point("2026-10-02", label: "10/2", source: .claude, tokens: 6_000_000),
                point("2026-10-02", label: "10/2", source: .codex, tokens: 3_000_000),
                point("2026-10-03", label: "10/3", source: .claude, tokens: 2_000_000),
                point("2026-10-03", label: "10/3", source: .codex, tokens: 4_000_000),
            ],
            granularity: .day,
            rangeTitle: "近 30 天",
            apiValueByTrendBucket: [
                "2026-10-02": [.claude: 1.5],
            ],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["日期", "Claude", "Codex", "合计", "API 等价(USD)"])
        XCTAssertEqual(rows[1], ["2026-10-02", "6000000", "3000000", "9000000", "1.50"])
        // 当日该桶无金额(缺价)留空,不写 0.00
        XCTAssertEqual(rows[2], ["2026-10-03", "2000000", "4000000", "6000000", ""])
        // 合计行:逐来源求和;金额列合计留空(口径行说明)
        XCTAssertEqual(rows[3], ["合计", "8000000", "7000000", "15000000", ""])
        // 口径行自带范围/粒度/列序说明
        XCTAssertTrue(rows.contains { $0.first == "口径" })
        XCTAssertTrue(csv.contains("近 30 天 · 按日（与趋势图同桶）"))
        XCTAssertTrue(csv.contains("逐日一行（日期键为自然日）"))
        XCTAssertTrue(csv.contains("来源列按范围内合计降序（与图例一致）；图例点暗隐藏的来源不导出"))
        XCTAssertTrue(csv.contains("无金额留空；合计行金额留空"))
        XCTAssertTrue(csv.contains("导出于 2026-10-03"))
    }

    func testWeekAndMonthBucketsSortByKeyAndNoteAnchors() {
        let csv = OverviewTrendCSVExport.makeCSV(
            trend: [
                point("2026-09-07", label: "9/7周", source: .claude, tokens: 100),
                point("2026-09-14", label: "9/14周", source: .claude, tokens: 200),
            ],
            granularity: .week,
            rangeTitle: "全部历史",
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[1][0], "2026-09-07")
        XCTAssertEqual(rows[2][0], "2026-09-14")
        XCTAssertTrue(csv.contains("周桶锚定周一（日期键为该周周一）"))
        // 月档口径行注明月锚定
        let monthCSV = OverviewTrendCSVExport.makeCSV(
            trend: [point("2026-09-01", label: "9月", source: .claude, tokens: 5)],
            granularity: .month, rangeTitle: "全部历史")
        XCTAssertTrue(monthCSV.contains("月桶为自然月（日期键为该月 1 日）"))
    }

    func testHourModeHasNoAmountColumnAndNotesTodayTotal() {
        // 小时档:首列为小时,无金额列;今日合计金额落口径行
        let csv = OverviewTrendCSVExport.makeCSV(
            trend: [
                point("2026-10-03", label: "10/3", source: .claude, tokens: 10, hour: 10),
                point("2026-10-03", label: "10/3", source: .claude, tokens: 4, hour: 9),
                point("2026-10-03", label: "10/3", source: .codex, tokens: 6, hour: 9),
            ],
            granularity: .hour,
            rangeTitle: "今日",
            apiValueByTrendBucket: ["2026-10-03": [.claude: 2.0, .codex: 1.0]],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["小时", "Claude", "Codex", "合计"])
        // 钟点升序;同钟点来源分列
        XCTAssertEqual(rows[1], ["9", "4", "6", "10"])
        XCTAssertEqual(rows[2], ["10", "10", "0", "10"])
        XCTAssertEqual(rows[3], ["合计", "14", "6", "20"])
        XCTAssertTrue(csv.contains("小时 = 今日逐时（0-23 全钟点照列，无用量为 0）"))
        XCTAssertTrue(csv.contains("小时档无逐时金额；今日 API 等价合计 3.00 USD"))
        // 无金额时口径行仍说明小时档无逐时金额,不带合计句
        let noAmount = OverviewTrendCSVExport.makeCSV(
            trend: [point("2026-10-03", label: "10/3", source: .claude, tokens: 1, hour: 8)],
            granularity: .hour, rangeTitle: "今日")
        XCTAssertTrue(noAmount.contains("小时档无逐时金额"))
        XCTAssertFalse(noAmount.contains("今日 API 等价合计"))
    }

    func testEmptyTrendYieldsHeaderOnly() {
        let csv = OverviewTrendCSVExport.makeCSV(
            trend: [], granularity: .day, rangeTitle: "近 7 天", todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["日期", "合计", "API 等价(USD)"])
        // 无桶则无数据行也无合计行,口径行照附
        XCTAssertEqual(rows[1].first, "口径")
        XCTAssertFalse(rows.contains { $0.first == "合计" })
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    func testSuggestedFilenameCarriesRangeSlug() {
        XCTAssertEqual(
            OverviewTrendCSVExport.suggestedFilename(range: .day, todayKey: "2026-10-03"),
            "TokenMeter-trend-1d-2026-10-03.csv")
        XCTAssertEqual(
            OverviewTrendCSVExport.suggestedFilename(range: .week, todayKey: "2026-10-03"),
            "TokenMeter-trend-7d-2026-10-03.csv")
        XCTAssertEqual(
            OverviewTrendCSVExport.suggestedFilename(range: .all, todayKey: "2026-10-03"),
            "TokenMeter-trend-all-2026-10-03.csv")
    }
}
