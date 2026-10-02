import XCTest
@testable import TokenMeter

// DeepSeek 模型详情页 CSV：逐日一行 + 汇总/构成/费用口径行
final class DeepSeekModelCSVExportTests: XCTestCase {
    private let model = UsageModelSummary(
        key: "flash", name: "V4 Flash",
        totalTokens: 1_234_567, requestCount: 42,
        cacheHitTokens: 700_000, cacheMissTokens: 234_567,
        responseTokens: 300_000, cost: 12.5)

    func testDailyCSVCarriesWeekdayAndFooterCalibers() {
        // 2026-09-20 为周日 → 27 日仍为周日
        let csv = DeepSeekModelCSVExport.makeCSV(
            model: model,
            rows: [
                DeepSeekModelCSVExport.Row(date: "2026-09-27", tokens: 0),
                DeepSeekModelCSVExport.Row(date: "2026-09-28", tokens: 1_500_000),
                DeepSeekModelCSVExport.Row(date: "2026-09-29", tokens: 500_000),
            ],
            todayKey: "2026-09-29")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "日期,星期,Token")
        // 零用量日照列 0;星期与热力图同一套标签
        XCTAssertEqual(lines[1], "2026-09-27,日,0")
        XCTAssertEqual(lines[2], "2026-09-28,一,1500000")
        XCTAssertEqual(lines[3], "2026-09-29,二,500000")
        // 口径行整行:来源+模型+档位、聚合语义、平台合计语义、汇总、构成、
        // 费用口径(平台返回人民币,与 API 等价估算区分)、导出日期。
        // 数字保持原始整数(不加千分位),与导出套件其余成员同纪律
        XCTAssertEqual(
            lines[4],
            "口径,DeepSeek V4 Flash · 近 7 天,"
                + "逐日一行（滚动窗口含今天，无用量日照列 0）,"
                + "Token为平台返回的当日该模型合计,"
                + "汇总：总 Token 1234567 · 请求数 42 · 消费 ¥12.50,"
                + "Token 构成（当月）：缓存命中 700000 / 未命中 234567 / 输出 300000,"
                + "消费为平台返回费用(人民币)，非 API 等价估算,"
                + "导出于 2026-09-29")
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    func testSuggestedFilenameUsesDisplayNameAndDate() {
        XCTAssertEqual(
            DeepSeekModelCSVExport.suggestedFilename(modelKey: "flash"),
            "TokenMeter-deepseek-V4-Flash-\(DateUtil.today()).csv")
        XCTAssertEqual(
            DeepSeekModelCSVExport.suggestedFilename(modelKey: "pro"),
            "TokenMeter-deepseek-V4-Pro-\(DateUtil.today()).csv")
    }
}
