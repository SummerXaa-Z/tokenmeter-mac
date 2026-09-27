import XCTest
@testable import TokenMeter

final class UsageCSVExportTests: XCTestCase {
    private func day(
        _ date: String,
        bySource: [HistorySource: Int] = [:],
        cost: Double = 0
    ) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(date: date, bySource: bySource, cost: cost)
    }

    private func parseRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
    }

    func testHeaderListsCodingSourcesThenPlatformColumns() {
        let rows = parseRows(UsageCSVExport.makeCSV([]))
        XCTAssertEqual(rows, [[
            "日期", "Claude", "Codex", "Kimi", "OpenCode", "Gemini",
            "Copilot", "Qwen Code", "Cursor", "Coding 合计",
            "DeepSeek 平台", "平台费用(USD)", "API 等价(USD)",
        ]])
    }

    func testRowsSortedByDateWithCodingTotalExcludingPlatform() {
        let csv = UsageCSVExport.makeCSV([
            day("2026-09-25", bySource: [.claude: 100, .deepseek: 40], cost: 1.5),
            day("2026-09-24", bySource: [.codex: 7, .qwen: 3]),
        ])
        let rows = parseRows(csv)
        XCTAssertEqual(rows.count, 3)

        XCTAssertEqual(rows[1][0], "2026-09-24")
        XCTAssertEqual(rows[1][1], "0")          // Claude
        XCTAssertEqual(rows[1][2], "7")          // Codex
        XCTAssertEqual(rows[1][7], "3")          // Qwen Code 列
        XCTAssertEqual(rows[1][8], "0")          // Cursor 列
        XCTAssertEqual(rows[1][9], "10")         // Coding 合计 = 7 + 3
        XCTAssertEqual(rows[1][11], "0.00")      // 平台费用

        XCTAssertEqual(rows[2][0], "2026-09-25")
        XCTAssertEqual(rows[2][1], "100")
        // 平台 Token 不进 Coding 合计
        XCTAssertEqual(rows[2][9], "100")
        XCTAssertEqual(rows[2][10], "40")
        XCTAssertEqual(rows[2][11], "1.50")
    }

    func testAPIValueColumnFillsOnlyDaysWithPricedModelDetail() {
        let values = UsageCSVExport.apiValueByDate([
            ModelUsageDay(date: "2026-09-24", bySource: [
                .codex: ["gpt-5.4": .init(output: 1_000_000)],
                .claude: ["opus-5-5": .init(input: 1_000_000)],
            ]),
            ModelUsageDay(date: "2026-09-25", bySource: [.qwen: ["private-model": .init(input: 5)]]),
        ])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values["2026-09-24"] ?? 0, 19, accuracy: 1e-9)

        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-24", bySource: [.codex: 1]),
            day("2026-09-25", bySource: [.qwen: 5]),
        ], apiValueByDate: values))
        XCTAssertEqual(rows.map(\.count), [13, 13, 13])
        XCTAssertEqual(rows[1][12], "19.00")
        XCTAssertEqual(rows[2][12], "")          // 全部缺价：留空而不是 0
    }

    func testEndsWithNewline() {
        XCTAssertTrue(UsageCSVExport.makeCSV([]).hasSuffix("\n"))
    }
}
