import XCTest
@testable import TokenMeter

// 24 小时分时卡导出：逐小时一行（小时升序、真实零照列 0）、合计行、
// 口径行（来源 + 逐时口径 + Qwen 归属脚注原样带出）。
final class SourceHourCSVExportTests: XCTestCase {
    private func parseRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
    }

    func testRowsSortByHourAndCarryNote() {
        // 乱序传入,导出按小时升序;零用量小时照列 0
        let csv = SourceHourCSVExport.makeCSV(
            source: .qwen,
            bars: [
                .init(hour: 21, tokens: 300),
                .init(hour: 9, tokens: 120),
                .init(hour: 15, tokens: 0),
            ],
            note: "Qwen 在 Session 结束时写入聚合记录，因此小时归属按 Session 结束时间。",
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["小时", "Token"])
        XCTAssertEqual(rows[1], ["9", "120"])
        XCTAssertEqual(rows[2], ["15", "0"])
        XCTAssertEqual(rows[3], ["21", "300"])
        XCTAssertEqual(rows[4], ["合计", "420"])
        // 口径行:来源 + 逐时口径,脚注原样带出
        XCTAssertTrue(csv.contains("Qwen Code · 今日逐时（与分时图同口径）"))
        XCTAssertTrue(csv.contains("Qwen 在 Session 结束时写入聚合记录，因此小时归属按 Session 结束时间。"))
        XCTAssertTrue(csv.contains("0-23 全钟点照列，无用量为 0（真实零）"))
        XCTAssertTrue(csv.contains("导出于 2026-10-03"))
    }

    func testClaudeOmitsNoteLine() {
        let csv = SourceHourCSVExport.makeCSV(
            source: .claude,
            bars: [.init(hour: 10, tokens: 7)],
            todayKey: "2026-10-03")
        XCTAssertTrue(csv.contains("Claude · 今日逐时（与分时图同口径）"))
        XCTAssertFalse(csv.contains("Session 结束"))
    }

    func testEmptyBarsYieldHeaderAndNotesOnly() {
        let csv = SourceHourCSVExport.makeCSV(
            source: .claude, bars: [], todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["小时", "Token"])
        XCTAssertEqual(rows[1].first, "口径")
        XCTAssertFalse(rows.contains { $0.first == "合计" })
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    func testSuggestedFilenameSanitizesSourceName() {
        XCTAssertEqual(
            SourceHourCSVExport.suggestedFilename(
                source: .claude, todayKey: "2026-10-03"),
            "TokenMeter-hours-Claude-2026-10-03.csv")
        // 空格折叠为连字符:Qwen Code → Qwen-Code
        XCTAssertEqual(
            SourceHourCSVExport.suggestedFilename(
                source: .qwen, todayKey: "2026-10-03"),
            "TokenMeter-hours-Qwen-Code-2026-10-03.csv")
    }
}
