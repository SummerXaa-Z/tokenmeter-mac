import XCTest
@testable import TokenMeter

// 来源页 7|30 天趋势卡导出：逐日一行、分量列与图例同名同序、星期列、
// 合计行与口径行（含各来源的分量折叠说明）。
final class SourceTrendCSVExportTests: XCTestCase {
    private func parseRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
    }

    private func day(
        _ date: String,
        _ parts: [(name: String, value: Int)]
    ) -> SourceTrendCard.Day {
        .init(date: date, parts: parts.map { ($0.name, $0.value, Theme.hit) })
    }

    func testCodexRowsCarryWeekdayAndFoldedParts() {
        // 2026-10-01 为周四、10-02 周五、10-03 周六;Codex 三段折叠
        let csv = SourceTrendCSVExport.makeCSV(
            source: .codex,
            spanDays: 7,
            days: [
                day("2026-10-01", [("缓存输入", 100), ("新输入", 20), ("输出", 30)]),
                day("2026-10-02", [("缓存输入", 0), ("新输入", 5), ("输出", 0)]),
            ],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["日期", "星期", "缓存输入", "新输入", "输出", "合计"])
        XCTAssertEqual(rows[1], ["2026-10-01", "四", "100", "20", "30", "150"])
        // 补零日:零分量照列 0
        XCTAssertEqual(rows[2], ["2026-10-02", "五", "0", "5", "0", "5"])
        XCTAssertEqual(rows[3], ["合计", "", "100", "25", "30", "155"])
        // 口径行:来源 + 档位 + 折叠说明 + 取数语义
        XCTAssertTrue(csv.contains("Codex · 近 7 天（与来源页趋势图同档同桶）"))
        XCTAssertTrue(csv.contains("输出 = 输出 + 推理（Codex 惯例，与图例一致）"))
        XCTAssertTrue(csv.contains("7 天档来自各页实时采集拼装"))
        XCTAssertTrue(csv.contains("补零时间轴：无用量日照列 0（真实零）"))
        XCTAssertTrue(csv.contains("导出于 2026-10-03"))
    }

    func testThirtyDaySpanNotesPersistedPipelineAndGeminiReasoningColumn() {
        let csv = SourceTrendCSVExport.makeCSV(
            source: .gemini,
            spanDays: 30,
            days: [day("2026-10-03", [
                ("缓存读取", 1), ("新输入", 2), ("输出", 3), ("推理", 4),
            ])],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(
            rows[0], ["日期", "星期", "缓存读取", "新输入", "输出", "推理", "合计"])
        XCTAssertEqual(rows[1], ["2026-10-03", "六", "1", "2", "3", "4", "10"])
        XCTAssertTrue(csv.contains("推理单列（与图例一致）"))
        XCTAssertTrue(csv.contains("30 天档来自本机按天留存，实时明细覆盖同一天"))
    }

    func testEmptyDaysYieldHeaderAndNotesOnly() {
        let csv = SourceTrendCSVExport.makeCSV(
            source: .claude, spanDays: 7, days: [], todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["日期", "星期", "合计"])
        XCTAssertEqual(rows[1].first, "口径")
        XCTAssertFalse(rows.contains { $0.first == "合计" })
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    func testSuggestedFilenameSanitizesSourceName() {
        XCTAssertEqual(
            SourceTrendCSVExport.suggestedFilename(
                source: .claude, spanDays: 7, todayKey: "2026-10-03"),
            "TokenMeter-trend-Claude-7d-2026-10-03.csv")
        // 空格折叠为连字符:Kimi Code → Kimi-Code
        XCTAssertEqual(
            SourceTrendCSVExport.suggestedFilename(
                source: .kimi, spanDays: 30, todayKey: "2026-10-03"),
            "TokenMeter-trend-Kimi-Code-30d-2026-10-03.csv")
    }

    // 单系列档(Cursor 历史趋势卡):按日合计、无分量列,乱序输入按日期升序
    func testSingleSeriesRowsSortByDateWithoutParts() {
        let csv = SourceTrendCSVExport.makeSingleSeriesCSV(
            source: .cursor,
            spanDays: 7,
            days: [
                ("2026-10-02", 400),
                ("2026-10-01", 900),
                ("2026-10-03", 0),   // 零天照列 0
            ],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["日期", "星期", "Token"])
        XCTAssertEqual(rows[1], ["2026-10-01", "四", "900"])
        XCTAssertEqual(rows[2], ["2026-10-02", "五", "400"])
        XCTAssertEqual(rows[3], ["2026-10-03", "六", "0"])
        XCTAssertEqual(rows[4], ["合计", "", "1300"])
        XCTAssertTrue(csv.contains("Cursor · 近 7 天（与来源页趋势卡同档）"))
        XCTAssertTrue(csv.contains("按日合计，来自本机按天历史（Cursor 仅有订阅周期聚合，无逐请求分量）"))
        // 单系列档没有分量折叠说明
        XCTAssertFalse(csv.contains("推理"))
        // 文件名与分量档同规格
        XCTAssertEqual(
            SourceTrendCSVExport.suggestedFilename(
                source: .cursor, spanDays: 7, todayKey: "2026-10-03"),
            "TokenMeter-trend-Cursor-7d-2026-10-03.csv")
    }
}
