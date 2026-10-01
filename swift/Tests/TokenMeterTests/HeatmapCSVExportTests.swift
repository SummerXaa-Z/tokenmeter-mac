import XCTest
@testable import TokenMeter

final class HeatmapCSVExportTests: XCTestCase {
    private func row(
        _ bucket: String,
        weekday: Int? = nil,
        tokens: Int,
        usd: Double? = nil
    ) -> HeatmapCSVExport.Row {
        HeatmapCSVExport.Row(bucket: bucket, weekday: weekday, tokens: tokens, usd: usd)
    }

    func testDayCSVHeaderRowsAndFootnote() {
        // 2026-09-29 周二(weekday 3 → 二)、09-30 周三(weekday 4 → 三);
        // 零 Token 行照列、无金额留空
        let csv = HeatmapCSVExport.makeCSV(
            rows: [
                row("2026-09-29", weekday: 3, tokens: 3_456_789, usd: 4.5),
                row("2026-09-30", weekday: 4, tokens: 0),
            ],
            granularity: .day,
            windowText: "2026-07-01 至 2026-09-30",
            todayKey: "2026-10-01")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "日期,星期,Token,API等价(USD)")
        XCTAssertEqual(lines[1], "2026-09-29,二,3456789,4.50")
        XCTAssertEqual(lines[2], "2026-09-30,三,0,")
        XCTAssertEqual(
            lines[3],
            "口径,粒度 日,窗口 2026-07-01 至 2026-09-30,"
                + "Token为本地按天历史合计（平台账户不计）,"
                + "API等价按用量当日生效价重算（缺价不计、无金额留空）,导出于 2026-10-01")
    }

    func testWeekCSVHasNoWeekdayColumn() {
        let csv = HeatmapCSVExport.makeCSV(
            rows: [row("2026-09-28", tokens: 12_000_000, usd: 31.2)],
            granularity: .week,
            windowText: "2026-07-06 至 2026-10-01",
            todayKey: "2026-10-01")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "周(周一),Token,API等价(USD)")
        XCTAssertEqual(lines[1], "2026-09-28,12000000,31.20")
        XCTAssertEqual(lines[2].hasPrefix("口径,粒度 周,窗口 2026-07-06 至 2026-10-01,"), true)
    }

    func testMonthCSVUsesMonthBucketTitle() {
        // 月档的当月进行中由数据本身体现(合计截至今天),CSV 不另加进行中列
        let csv = HeatmapCSVExport.makeCSV(
            rows: [row("2026-10", tokens: 36_000_000, usd: nil)],
            granularity: .month,
            windowText: "2025-11-01 至 2026-10-01",
            todayKey: "2026-10-01")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "月份,Token,API等价(USD)")
        XCTAssertEqual(lines[1], "2026-10,36000000,")
        XCTAssertEqual(lines[2].hasPrefix("口径,粒度 月,窗口 2025-11-01 至 2026-10-01,"), true)
    }

    func testUSDDecimalFormatting() {
        let csv = HeatmapCSVExport.makeCSV(
            rows: [
                row("2026-09-28", weekday: 2, tokens: 1, usd: 0.005),
                row("2026-09-29", weekday: 3, tokens: 1, usd: 1234.5),
            ],
            granularity: .day,
            windowText: "",
            todayKey: "2026-10-01")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1].hasSuffix(",0.01"), true)   // 四舍五入到两位
        XCTAssertEqual(lines[2].hasSuffix(",1234.50"), true)
    }

    func testWeekdayLabelMapsCalendarNumbersAndNilBlank() {
        XCTAssertEqual(HeatmapCSVExport.weekdayLabel(1), "日")
        XCTAssertEqual(HeatmapCSVExport.weekdayLabel(4), "三")
        XCTAssertEqual(HeatmapCSVExport.weekdayLabel(7), "六")
        XCTAssertEqual(HeatmapCSVExport.weekdayLabel(nil), "")
        XCTAssertEqual(HeatmapCSVExport.weekdayLabel(0), "")
        XCTAssertEqual(HeatmapCSVExport.weekdayLabel(8), "")
    }

    func testSuggestedFilenameContainsToday() {
        XCTAssertEqual(
            HeatmapCSVExport.suggestedFilename(), "TokenMeter-heatmap-\(DateUtil.today()).csv")
    }
}
