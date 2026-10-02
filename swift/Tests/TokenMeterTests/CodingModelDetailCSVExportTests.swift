import XCTest
@testable import TokenMeter

final class CodingModelDetailCSVExportTests: XCTestCase {
    func testDailyRowsCarryWeekdayAndBlankUSD() {
        let csv = CodingModelDetailCSVExport.makeCSV(
            source: .claude,
            model: "opus-5-5",
            spanDays: 30,
            rows: [
                .init(bucket: "2026-09-29", tokens: 3_456_789, usd: 4.5),
                .init(bucket: "2026-09-30", tokens: 0, usd: 0),      // 无用量日照列 0
                .init(bucket: "2026-10-01", tokens: 800_000, usd: nil),   // 无计价金额留空
            ],
            coverage: nil,
            todayKey: "2026-10-02")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "日期,星期,Token,API等价(USD)")
        // Calendar weekday:2026-09-29 周二、09-30 周三、10-01 周四
        XCTAssertEqual(lines[1], "2026-09-29,二,3456789,4.50")
        XCTAssertEqual(lines[2], "2026-09-30,三,0,")
        XCTAssertEqual(lines[3], "2026-10-01,四,800000,")
        XCTAssertTrue(lines[4].hasPrefix("口径,"))
        XCTAssertTrue(lines[4].contains("Claude opus-5-5 · 近 30 天"), "无半角逗号不加引号")
        XCTAssertFalse(lines[4].contains("价格覆盖"), "覆盖率为 nil 时不给覆盖段")
    }

    func testQuarterRowsAggregateByWeek() {
        let csv = CodingModelDetailCSVExport.makeCSV(
            source: .kimi,
            model: "mystery-model",
            spanDays: 90,
            rows: [
                .init(bucket: "2026-09-21", tokens: 9_000_000, usd: 12.345),
                .init(bucket: "2026-09-28", tokens: 0, usd: 0),
            ],
            coverage: 0.942,
            todayKey: "2026-10-02")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "周(周一),Token,API等价(USD)")
        XCTAssertEqual(lines[1], "2026-09-21,9000000,12.35")   // 两位小数
        XCTAssertEqual(lines[2], "2026-09-28,0,")
        XCTAssertTrue(lines[3].contains("90 天档按自然周聚合（周一为界，首尾周可能不足整周）"))
        XCTAssertTrue(lines[3].contains("价格覆盖 94%"), "覆盖不足时点名")
    }

    func testSuggestedFilenameSanitizesModelName() {
        XCTAssertEqual(
            CodingModelDetailCSVExport.suggestedFilename(model: "opus-5-5"),
            "TokenMeter-model-opus-5-5-\(DateUtil.today()).csv")
        // 名字带空格/括号换连字符折叠;空名回退通用名
        XCTAssertEqual(
            CodingModelDetailCSVExport.suggestedFilename(model: "gpt-5.4 (xhigh)"),
            "TokenMeter-model-gpt-5-4-xhigh-\(DateUtil.today()).csv")
        XCTAssertEqual(
            CodingModelDetailCSVExport.suggestedFilename(model: ""),
            "TokenMeter-model-model-\(DateUtil.today()).csv")
    }
}
