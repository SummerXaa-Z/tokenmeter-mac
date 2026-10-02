import XCTest
@testable import TokenMeter

// 总览环比卡导出：合计行 + 各来源行（本期/上期/环比），行序与卡片一致，
// 无基期留空、数字为原始整数。
final class PeriodCompareCSVExportTests: XCTestCase {
    private func parseRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
    }

    func testRowsMatchCardOrderWithTotalFirst() {
        // 两期较大值降序:Claude(120) > Codex(80) > Kimi(10);
        // 环比 +50% / 无基期留空;合计 210 vs 84 = +150%
        let csv = PeriodCompareCSVExport.makeCSV(
            period: .week,
            this: [.claude: 120, .codex: 80, .kimi: 10],
            last: [.claude: 80, .kimi: 4],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["来源", "本期 Token", "上期 Token", "环比"])
        XCTAssertEqual(rows[1], ["合计", "210", "84", "+150%"])
        XCTAssertEqual(rows[2], ["Claude", "120", "80", "+50%"])
        XCTAssertEqual(rows[3], ["Codex", "80", "0", ""])
        XCTAssertEqual(rows[4], ["Kimi Code", "10", "4", "+150%"])
        // 口径行:周期语义 + 环比公式 + 行序说明
        XCTAssertTrue(csv.contains("本周 vs 上周（日历周口径，本周截至今天）"))
        XCTAssertTrue(csv.contains("环比 = (本期 - 上期) / 上期；上期为 0（无基期）留空"))
        XCTAssertTrue(csv.contains("行序 = 两期较大值降序（合计行除外，与卡片一致）"))
        XCTAssertTrue(csv.contains("导出于 2026-10-03"))
    }

    func testDownTrendCarriesMinusSign() {
        let csv = PeriodCompareCSVExport.makeCSV(
            period: .rolling7,
            this: [.claude: 50], last: [.claude: 100],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[1], ["合计", "50", "100", "-50%"])
        XCTAssertTrue(csv.contains("近 7 天 vs 前 7 天（滚动 7 天窗口，截至今天）"))
    }

    func testEmptyPeriodsYieldTotalsOnly() {
        // 两期全空:只剩合计行(0/0/留空),不出现来源行
        let csv = PeriodCompareCSVExport.makeCSV(
            period: .month, this: [:], last: [:], todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["来源", "本期 Token", "上期 Token", "环比"])
        XCTAssertEqual(rows[1], ["合计", "0", "0", ""])
        XCTAssertEqual(rows[2].first, "口径")
    }

    func testSuggestedFilenameCarriesPeriodSlug() {
        XCTAssertEqual(
            PeriodCompareCSVExport.suggestedFilename(period: .week, todayKey: "2026-10-03"),
            "TokenMeter-compare-week-2026-10-03.csv")
        XCTAssertEqual(
            PeriodCompareCSVExport.suggestedFilename(period: .rolling7, todayKey: "2026-10-03"),
            "TokenMeter-compare-7d-2026-10-03.csv")
        XCTAssertEqual(
            PeriodCompareCSVExport.suggestedFilename(period: .month, todayKey: "2026-10-03"),
            "TokenMeter-compare-month-2026-10-03.csv")
    }
}
