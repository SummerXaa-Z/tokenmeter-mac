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
           plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY")],
           todayKey: "2026-09-28"))
        let text = try XCTUnwrap(
            rows.first { $0.first == "订阅回本" }?.joined(separator: ","))
        XCTAssertTrue(text.contains("订阅月费合计(USD) 20.00"), text)
        XCTAssertTrue(text.contains("折算天数 5"), text)
        XCTAssertTrue(text.contains("折算订阅费(USD) 3.29"), text)   // 20×12/365×5
        XCTAssertTrue(text.contains("API 等价合计(USD) 2.44"), text)
        XCTAssertTrue(text.contains("回本倍数 0.74"), text)
    }

    // MARK: - 订阅回本·周明细行

    func testRoiWeeklyRowsFollowCurvePipeline() throws {
        // 与总览曲线同管线:全部 Coding 来源聚合(Kimi 9/22 旧价 $2.44/M +
        // Claude opus-5.5 9/23 $20/M),周费 $100×12/365×7 = $23.01;
        // 留存从 09-07 起 → 此前的周费用 0、倍数「—」
        let modelHistory = [
            ModelUsageDay(date: "2026-09-07", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 2_000_000)]),
            ]),
            ModelUsageDay(date: "2026-09-14", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 5_000_000)]),
            ]),
            ModelUsageDay(date: "2026-09-22", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 3_000_000)]),
            ]),
            ModelUsageDay(date: "2026-09-23", bySource: [
                .claude: SourceDayDetail(models: ["opus-5-5": .init(output: 1_000_000)]),
            ]),
        ]
        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-22", bySource: [.kimi: 300]),
            day("2026-09-23", bySource: [.claude: 50]),
        ], apiValueByDate: UsageCSVExport.apiValueByDate(modelHistory),
           modelHistory: modelHistory,
           plans: [SubscriptionPlan(name: "Claude Max", monthlyFee: 100)],
           todayKey: "2026-09-28"))
        let weekly = rows.filter { $0.first == "订阅回本·周明细" }
        XCTAssertEqual(weekly.count, 13)
        // 订阅回本行在周明细之前
        let subscriptionIndex = try XCTUnwrap(
            rows.firstIndex { $0.first == "订阅回本" })
        let firstWeeklyIndex = try XCTUnwrap(
            rows.firstIndex { $0.first == "订阅回本·周明细" })
        XCTAssertLessThan(subscriptionIndex, firstWeeklyIndex)
        // 留存起点之前:整周无费用、倍数留「—」
        XCTAssertEqual(weekly.first?.dropFirst().prefix(2),
                       ["周(周一) 2026-06-29", "API 等价(USD) 0.00"])
        XCTAssertTrue(weekly.first?.contains("折算订阅费(USD) 0.00") ?? false)
        XCTAssertTrue(weekly.first?.contains("回本倍数 —") ?? false)
        // 最近一个完整周:双来源金额聚合进同一周
        XCTAssertEqual(weekly.last?.dropFirst().prefix(3), [
            "周(周一) 2026-09-21",
            "API 等价(USD) 27.32",     // 3M×2.44 + 1M×20
            "折算订阅费(USD) 23.01",    // 100×12/365×7
        ])
        XCTAssertTrue(weekly.last?.contains("回本倍数 1.19") ?? false)
        // 有数据的中间周各成一行
        let middle = weekly.first { $0.contains("周(周一) 2026-09-14") }
        XCTAssertTrue(middle?.contains("API 等价(USD) 12.20") ?? false)
        XCTAssertTrue(middle?.contains("回本倍数 0.53") ?? false)
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
        // 表头 + 2 天 + 汇总 + 价格覆盖率 + 订阅回本 + 13 行周明细
        XCTAssertEqual(rows.count, 19)
        XCTAssertEqual(rows[1][0], "2026-09-22")
        XCTAssertFalse(rows.contains { $0.first == "2026-09-18" })
        // 汇总只算范围内:Kimi 200+300,API 等价 2.44+4.00
        XCTAssertEqual(rows[3][0], "汇总")
        XCTAssertEqual(rows[3][3], "500")
        XCTAssertEqual(rows[3][12], "6.44")
        // 覆盖率同样只算范围内(09-18 的明细不计入)
        XCTAssertEqual(rows[4][0], "价格覆盖率")
        XCTAssertTrue(rows[4].joined(separator: ",").contains("覆盖率 100.0%"))
        let text = try XCTUnwrap(
            rows.first { $0.first == "订阅回本" }?.joined(separator: ","))
        XCTAssertTrue(text.contains("折算天数 5"), text)          // 09-22..09-26
        XCTAssertTrue(text.contains("折算订阅费(USD) 3.29"), text)  // 20×12/365×5
        XCTAssertTrue(text.contains("API 等价合计(USD) 6.44"), text)
        XCTAssertTrue(text.contains("回本倍数 1.96"), text)        // 6.44/3.29
        // 周明细不随导出范围截取:today=09-26 的最近完整周是 09-14,
        // 留存自 09-18 起 → 该周摊 3 天、含 09-18 的 $2.44
        let weekly = rows.filter { $0.first == "订阅回本·周明细" }
        XCTAssertEqual(weekly.count, 13)
        let lastWeekRow = weekly.first { $0.contains("周(周一) 2026-09-14") }
        XCTAssertTrue(lastWeekRow?.contains("折算订阅费(USD) 1.97") ?? false)  // 20×12/365×3
        XCTAssertTrue(lastWeekRow?.contains("API 等价(USD) 2.44") ?? false)
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

    // MARK: - 周报导出（固定窗口档）

    func testWindowRangeFiltersRowsAndProratesFullWeek() throws {
        // 上周 = 09-14(周一)..09-20(周日);窗口外的 09-13/09-21 不导出;
        // 明细留存从 09-16 起 → 折算从 09-16 到 09-20 共 5 天,
        // 周日(09-20)没有用量行也计入折算终点(与周报同整周口径)
        let modelHistory = [
            ModelUsageDay(date: "2026-09-16", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 1_000_000)]),
            ]),
        ]
        let apiValues = UsageCSVExport.apiValueByDate(modelHistory)
        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-13", bySource: [.kimi: 999]),
            day("2026-09-15", bySource: [.kimi: 100]),
            day("2026-09-16", bySource: [.kimi: 50]),
            day("2026-09-19", bySource: [.kimi: 200]),
            day("2026-09-21", bySource: [.kimi: 777]),
        ], apiValueByDate: apiValues, modelHistory: modelHistory,
           plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY")],
           range: .window(start: "2026-09-14", end: "2026-09-20")))
        // 表头 + 3 天 + 汇总 + 价格覆盖率 + 订阅回本 + 13 行周明细
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(rows[1][0], "2026-09-15")
        XCTAssertFalse(rows.contains { $0.first == "2026-09-13" })
        XCTAssertFalse(rows.contains { $0.first == "2026-09-21" })
        XCTAssertEqual(rows[4][0], "汇总")
        XCTAssertEqual(rows[4][3], "350")          // 100+50+200
        XCTAssertEqual(rows[4][12], "2.44")
        let text = try XCTUnwrap(
            rows.first { $0.first == "订阅回本" }?.joined(separator: ","))
        XCTAssertTrue(text.contains("折算天数 5"), text)            // 09-16..09-20
        XCTAssertTrue(text.contains("折算订阅费(USD) 3.29"), text)
        XCTAssertTrue(text.contains("API 等价合计(USD) 2.44"), text)
        XCTAssertTrue(text.contains("回本倍数 0.74"), text)
        // 周明细按 today 的完整周计算,窗口外的当周照常成行(不随导出范围截取)
        XCTAssertEqual(rows.filter { $0.first == "订阅回本·周明细" }.count, 13)
    }

    func testLastWeekWindowMatchesDigestISOWeek() {
        // 无论周日还是周一取「上周」,都落在同一个已结束的 ISO 周
        let fromSunday = UsageCSVExport.lastWeekWindow(
            today: DateUtil.date(from: "2026-09-27")!)   // 周日
        XCTAssertEqual(fromSunday, .window(start: "2026-09-14", end: "2026-09-20"))
        let fromMonday = UsageCSVExport.lastWeekWindow(
            today: DateUtil.date(from: "2026-09-21")!)   // 周一
        XCTAssertEqual(fromMonday, .window(start: "2026-09-14", end: "2026-09-20"))
        let midWeek = UsageCSVExport.lastWeekWindow(
            today: DateUtil.date(from: "2026-09-24")!)   // 周四
        XCTAssertEqual(midWeek, .window(start: "2026-09-14", end: "2026-09-20"))
    }

    func testSuggestedFilenameWindowSuffix() {
        // 固定窗口的文件名直接标出起止(月日),周报导出与自定义起止共用
        let name = UsageCSVExport.suggestedFilename(
            range: .window(start: "2026-09-14", end: "2026-09-20"))
        XCTAssertTrue(name.hasSuffix("-0914-0920.csv"), name)
    }

    func testWindowStartAfterEndYieldsHeaderOnly() {
        // 自定义起止选反时不出明细行,也不出汇总/订阅回本行
        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-15", bySource: [.kimi: 100]),
        ], apiValueByDate: ["2026-09-15": 2],
           plans: [SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY")],
           range: .window(start: "2026-09-20", end: "2026-09-14")))
        XCTAssertEqual(rows.count, 1)   // 仅表头
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

    // MARK: - 通知快捷动作的直落导出（不经保存面板）

    func testWriteLastWeekCSVWritesWindowFileToDirectory() throws {
        // today = 2026-10-03(周六):上周窗口 = 09-21(周一)...09-27(周日),
        // 与周报同口径;窗外日期不进文件,文件名与 suggestedFilename 同源
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let today = DateUtil.date(from: "2026-10-03")!
        let filename = UsageCSVExport.writeLastWeekCSV(
            directory: directory,
            days: [
                day("2026-09-20", bySource: [.claude: 50]),   // 上上周日,窗外
                day("2026-09-21", bySource: [.claude: 100]),
                day("2026-09-27", bySource: [.claude: 200]),
                day("2026-10-02", bySource: [.claude: 999]),  // 本周,窗外
            ],
            apiValueByDate: [:], modelHistory: [], plans: [],
            today: today)
        let expectedRange = UsageCSVExport.lastWeekWindow(today: today)
        XCTAssertEqual(filename, UsageCSVExport.suggestedFilename(range: expectedRange!))
        let url = directory.appendingPathComponent(filename!)
        let rows = parseRows(try String(contentsOf: url, encoding: .utf8))
        // 表头 + 窗口 2 天 + 汇总行;modelHistory 与订阅为空,无覆盖率/回本行
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[1][0], "2026-09-21")
        XCTAssertEqual(rows[2][0], "2026-09-27")
        XCTAssertFalse(rows.contains { $0.contains("2026-09-20") })
        XCTAssertFalse(rows.contains { $0.contains("2026-10-02") })
    }

    func testWriteLastWeekCSVReturnsNilWhenDirectoryMissing() {
        // 目录不存在 → 写盘失败返回 nil,调用方据此回执失败通知
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertNil(UsageCSVExport.writeLastWeekCSV(
            directory: missing,
            days: [day("2026-09-22", bySource: [.claude: 10])],
            apiValueByDate: [:], modelHistory: [], plans: []))
    }

    // MARK: - 价格覆盖率行

    func testPriceCoverageRowReportsRatioAndUnpricedModels() throws {
        // 一天 kimi 有价(1M output)、一天 qwen 私有模型缺价(1M input):
        // 覆盖 1M / 2M = 50%,缺价模型点名
        let modelHistory = [
            ModelUsageDay(date: "2026-09-24", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 1_000_000)]),
            ]),
            ModelUsageDay(date: "2026-09-25", bySource: [
                .qwen: SourceDayDetail(models: ["private-model": .init(input: 1_000_000)]),
            ]),
        ]
        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-24", bySource: [.kimi: 100]),
            day("2026-09-25", bySource: [.qwen: 100]),
        ], modelHistory: modelHistory))
        XCTAssertEqual(rows[3][0], "汇总")
        XCTAssertEqual(rows[4][0], "价格覆盖率")
        let text = try XCTUnwrap(rows[4].joined(separator: ","))
        XCTAssertTrue(text.contains("覆盖率 50.0%"), text)
        XCTAssertTrue(text.contains("覆盖 tokens 1000000 / 2000000"), text)
        XCTAssertTrue(text.contains("缺价模型 private-model"), text)
    }

    func testPriceCoverageRowFullCoverageOmitsModelsAndWindowScopes() {
        let modelHistory = [
            ModelUsageDay(date: "2026-09-24", bySource: [
                .kimi: SourceDayDetail(models: ["kimi-k2.6": .init(output: 1_000_000)]),
            ]),
        ]
        // 全部有价：不附缺价 cell
        let rows = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-24", bySource: [.kimi: 100]),
        ], modelHistory: modelHistory))
        XCTAssertEqual(rows[3][0], "价格覆盖率")
        XCTAssertEqual(rows[3].count, 3)
        XCTAssertTrue(rows[3].joined(separator: ",").contains("覆盖率 100.0%"))

        // 明细全在窗口外：没有明细行也没有汇总/覆盖率行，仅表头
        let scoped = parseRows(UsageCSVExport.makeCSV([
            day("2026-09-24", bySource: [.kimi: 100]),
        ], modelHistory: modelHistory,
           range: .window(start: "2026-09-30", end: "2026-10-01")))
        XCTAssertEqual(scoped.count, 1)
    }
}
