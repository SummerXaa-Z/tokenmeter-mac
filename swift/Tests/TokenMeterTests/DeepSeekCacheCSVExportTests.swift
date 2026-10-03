import XCTest
@testable import TokenMeter

// DeepSeek 缓存命中明细卡导出：近 7 天滚动窗口（含今天）逐日一行、
// Flash + Pro 合并三系列列、合计行与口径行（命中率分母不含输出）。
final class DeepSeekCacheCSVExportTests: XCTestCase {
    private func parseRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
    }

    /// 相对今天第 offset 天的日期键(导出走 recentDays 滚动窗口,测试日期须跟随运行时)
    private func dayKey(_ offset: Int) -> String {
        DateUtil.key(DateUtil.addDays(Date(), offset))
    }

    private func weekday(_ offset: Int) -> String {
        HeatmapCSVExport.weekdayLabel(
            Calendar.current.component(.weekday, from: DateUtil.addDays(Date(), offset)))
    }

    private func makeDay(
        _ offset: Int, hit: Int, miss: Int, resp: Int
    ) -> UsageDay {
        .init(
            date: dayKey(offset),
            flashTokens: hit + miss + resp,
            flashCacheHit: hit,
            flashCacheMiss: miss,
            flashResponse: resp,
            proTokens: 0,
            proCacheHit: 0,
            proCacheMiss: 0,
            proResponse: 0,
            totalTokens: hit + miss + resp,
            totalCost: 0)
    }

    func testRowsMergeFlashAndProWithinRollingWindow() {
        // 只给昨天数据;recentDays 补零出 7 天骨架(升序、含今天),
        // 昨天落在骨架第 6 行(索引 5)
        let csv = DeepSeekCacheCSVExport.makeCSV(
            days: [
                makeDay(-1, hit: 300, miss: 100, resp: 200),
                makeDay(-8, hit: 999, miss: 999, resp: 999),   // 窗口外,应被丢弃
            ],
            todayKey: "2026-10-03")
        let rows = parseRows(csv)
        XCTAssertEqual(rows[0], ["日期", "星期", "命中", "未命中", "输出", "合计"])
        XCTAssertEqual(rows.count, 1 + 7 + 1 + 6)   // 表头 + 7 天 + 合计 + 6 行口径
        XCTAssertEqual(rows[1], [dayKey(-6), weekday(-6), "0", "0", "0", "0"])
        XCTAssertEqual(rows[5], [dayKey(-2), weekday(-2), "0", "0", "0", "0"])
        XCTAssertEqual(rows[6], [dayKey(-1), weekday(-1), "300", "100", "200", "600"])
        XCTAssertEqual(rows[7], [dayKey(0), weekday(0), "0", "0", "0", "0"])
        XCTAssertEqual(rows[8], ["合计", "", "300", "100", "200", "600"])
        // 窗口外的 8 天前数据没有混进来
        XCTAssertFalse(csv.contains("999"))
    }

    func testWindowRateInNotesExcludesResponseFromDenominator() {
        // 命中 300 / (300+100) = 75%,输出不计入分母
        let csv = DeepSeekCacheCSVExport.makeCSV(
            days: [makeDay(0, hit: 300, miss: 100, resp: 200)],
            todayKey: "2026-10-03")
        XCTAssertTrue(csv.contains("命中率 = 命中 ÷（命中 + 未命中），输出不计入分母；窗口合计命中率 75%"))
        XCTAssertTrue(csv.contains("DeepSeek 平台 · 近 7 天滚动窗口含今天（与卡片同窗口）"))
        XCTAssertTrue(csv.contains("V4 Flash 与 V4 Pro 合并展示（与卡片图例一致）"))
        XCTAssertTrue(csv.contains("导出于 2026-10-03"))
    }

    func testSuggestedFilename() {
        XCTAssertEqual(
            DeepSeekCacheCSVExport.suggestedFilename(todayKey: "2026-10-03"),
            "TokenMeter-deepseek-cache-2026-10-03.csv")
    }
}
