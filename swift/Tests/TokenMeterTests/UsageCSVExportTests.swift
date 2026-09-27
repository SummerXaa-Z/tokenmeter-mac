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
        XCTAssertEqual(rows.count, 4)   // 表头 + 2 天 + 汇总

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

        // 汇总行与表头同列对齐:逐来源求和
        XCTAssertEqual(rows[3][0], "汇总")
        XCTAssertEqual(rows[3][1], "100")
        XCTAssertEqual(rows[3][2], "7")
        XCTAssertEqual(rows[3][7], "3")
        XCTAssertEqual(rows[3][9], "110")
        XCTAssertEqual(rows[3][10], "40")
        XCTAssertEqual(rows[3][11], "1.50")
        XCTAssertEqual(rows[3][12], "0.00")     // 无金额明细
    }

    func testAPIValueColumnFillsOnlyDaysWithPricedModelDetail() {
        let values = UsageCSVExport.apiValueByDate([
            ModelUsageDay(date: "2026-09-24", bySource: [
                .codex: SourceDayDetail(models: ["gpt-5.4": .init(output: 1_000_000)]),
                .claude: SourceDayDetail(models: ["opus-5-5": .init(input: 1_000_000)]),
            ]),
            ModelUsageDay(date: "2026-09-25", bySource: [
                .qwen: SourceDayDetail(models: ["private-model": .init(input: 5)]),
            ]),
        ])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values["2026-09-24"] ?? 0, 19, accuracy: 1e-9)

        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-24", bySource: [.codex: 1]),
            day("2026-09-25", bySource: [.qwen: 5]),
        ], apiValueByDate: values))
        XCTAssertEqual(rows.map(\.count), [13, 13, 13, 13])   // 含末尾汇总行
        XCTAssertEqual(rows[1][12], "19.00")
        XCTAssertEqual(rows[2][12], "")          // 全部缺价：留空而不是 0
        XCTAssertEqual(rows[3][12], "19.00")     // 汇总行的 API 等价合计
    }

    // MARK: - 订阅回本行

    func testSubscriptionRowProratesOverExportSpanWithDetailClamp() throws {
        // 导出 09-20..09-26(7 天),明细从 09-22 起 → 折算 5 天;
        // 月费 ¥138 = $20,API 等价合计 $2.44(09-22 旧价) → 回本 2.44/(20×12/365×5) ≈ 0.74
        let modelHistory = [
            ModelUsageDay(date: "2026-09-22", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 1_000_000)]),
            ]),
        ]
        let apiValues = UsageCSVExport.apiValueByDate(modelHistory)
        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-20", bySource: [.kimi: 100]),
            day("2026-09-22", bySource: [.kimi: 150]),
            day("2026-09-26", bySource: [.kimi: 200]),
        ], apiValueByDate: apiValues, modelHistory: modelHistory,
           plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY")]))
        XCTAssertEqual(rows.last?.first, "订阅回本")
        let text = try XCTUnwrap(rows.last?.joined(separator: ","))
        XCTAssertTrue(text.contains("订阅月费合计(USD) 20.00"), text)
        XCTAssertTrue(text.contains("折算天数 5"), text)
        XCTAssertTrue(text.contains("折算订阅费(USD) 3.29"), text)   // 20×12/365×5
        XCTAssertTrue(text.contains("API 等价合计(USD) 2.44"), text)
        XCTAssertTrue(text.contains("回本倍数 0.74"), text)
    }

    func testSubscriptionRowOmittedWithoutPlans() {
        let csv = UsageCSVExport.makeCSV([
            day("2026-09-24", bySource: [.claude: 10]),
        ], apiValueByDate: ["2026-09-24": 5])
        let rows = parseRows(csv)
        XCTAssertEqual(rows.last?.first, "汇总")   // 无订阅:止于汇总行
    }

    // MARK: - 导出范围

    func testRangeLastDaysScopesRowsTotalsAndSubscription() throws {
        // 近 5 天(today=09-26) → 起点 09-22:09-18 行被剔除,
        // 汇总与订阅回本都只统计范围内的天(09-18 的金额不计入)
        let modelHistory = [
            ModelUsageDay(date: "2026-09-18", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 1_000_000)]),
            ]),
            ModelUsageDay(date: "2026-09-22", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 1_000_000)]),
            ]),
            ModelUsageDay(date: "2026-09-26", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 1_000_000)]),
            ]),
        ]
        let apiValues = UsageCSVExport.apiValueByDate(modelHistory)
        // 09-22 旧价 $2.44 + 09-26 新价 $4.00 = $6.44
        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-18", bySource: [.kimi: 100]),
            day("2026-09-22", bySource: [.kimi: 200]),
            day("2026-09-26", bySource: [.kimi: 300]),
        ], apiValueByDate: apiValues, modelHistory: modelHistory,
           plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY")],
           range: .lastDays(5), todayKey: "2026-09-26"))
        XCTAssertEqual(rows.count, 5)   // 表头 + 2 天 + 汇总 + 订阅回本
        XCTAssertEqual(rows[1][0], "2026-09-22")
        XCTAssertFalse(rows.contains { $0.first == "2026-09-18" })
        // 汇总只算范围内:Kimi 200+300,API 等价 2.44+4.00
        XCTAssertEqual(rows[3][0], "汇总")
        XCTAssertEqual(rows[3][3], "500")
        XCTAssertEqual(rows[3][12], "6.44")
        let text = try XCTUnwrap(rows.last?.joined(separator: ","))
        XCTAssertTrue(text.contains("折算天数 5"), text)          // 09-22..09-26
        XCTAssertTrue(text.contains("折算订阅费(USD) 3.29"), text)  // 20×12/365×5
        XCTAssertTrue(text.contains("API 等价合计(USD) 6.44"), text)
        XCTAssertTrue(text.contains("回本倍数 1.96"), text)        // 6.44/3.29
    }

    func testRangeBeyondHistoryKeepsEverything() {
        let days = [
            day("2026-09-18", bySource: [.kimi: 100]),
            day("2026-09-26", bySource: [.kimi: 300]),
        ]
        let all = parseRows(UsageCSVExport.makeCSV(days))
        let scoped = parseRows(UsageCSVExport.makeCSV(
            days, range: .lastDays(90), todayKey: "2026-09-26"))
        XCTAssertEqual(scoped.count, all.count)
        XCTAssertEqual(scoped.map { $0.first }, all.map { $0.first })
    }

    func testWindowStartDateKeyBoundaries() {
        XCTAssertNil(UsageCSVExport.windowStartDateKey(.all, todayKey: "2026-09-26"))
        XCTAssertEqual(
            UsageCSVExport.windowStartDateKey(.lastDays(7), todayKey: "2026-09-26"),
            "2026-09-20")
        XCTAssertEqual(
            UsageCSVExport.windowStartDateKey(.lastDays(1), todayKey: "2026-09-26"),
            "2026-09-26")
    }

    func testSuggestedFilenameCarriesRange() {
        XCTAssertTrue(UsageCSVExport.suggestedFilename(range: .lastDays(30))
            .hasSuffix("-30d.csv"))
        XCTAssertTrue(UsageCSVExport.suggestedFilename(range: .lastDays(90))
            .hasSuffix("-90d.csv"))
        let all = UsageCSVExport.suggestedFilename()
        XCTAssertTrue(all.hasPrefix("TokenMeter-usage-"))
        XCTAssertTrue(all.hasSuffix(".csv"))
        XCTAssertFalse(all.contains("-30d"))
    }

    func testEndsWithNewline() {
        XCTAssertTrue(UsageCSVExport.makeCSV([]).hasSuffix("\n"))
    }
}
