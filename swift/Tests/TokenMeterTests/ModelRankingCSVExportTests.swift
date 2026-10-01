import XCTest
@testable import TokenMeter

final class ModelRankingCSVExportTests: XCTestCase {
    private func row(
        _ rank: Int,
        source: String = "Claude",
        model: String = "opus-5-5",
        rangeTokens: Int = 524_000_000,
        share: Double = 0.62,
        week: Int? = 84_000_000,
        month: Int? = 524_000_000,
        usd: Double? = 54.5,
        activeDays: Int? = 10,
        price: String = "$3 / $15 /M"
    ) -> ModelRankingCSVExport.Row {
        ModelRankingCSVExport.Row(
            rank: rank, source: source, model: model, rangeTokens: rangeTokens,
            sharePercent: share, weekTokens: week, monthTokens: month,
            monthUSD: usd, activeDays: activeDays, priceNote: price)
    }

    func testMakeCSVHeaderRowsAndScopeLine() {
        let csv = ModelRankingCSVExport.makeCSV(
            rows: [row(1), row(2, source: "Codex", model: "gpt-5.4 (xhigh)",
                       rangeTokens: 86_000_000, share: 0.1, usd: 61.25)],
            scopeTitle: "近 30 天",
            sortTitle: "等价",
            todayKey: "2026-10-01")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0],
            "名次,来源,模型,范围Token,范围占比%,近7天Token,近30天Token,近30天API等价(USD),近30天活跃天数,参考单价")
        XCTAssertEqual(lines[1],
            "1,Claude,opus-5-5,524000000,62,84000000,524000000,54.50,10,$3 / $15 /M")
        XCTAssertEqual(lines[2],
            "2,Codex,gpt-5.4 (xhigh),86000000,10,84000000,524000000,61.25,10,$3 / $15 /M")
        XCTAssertEqual(lines[3],
            "口径,范围 近 30 天,排序 等价,等价与近7天来自近30天明细留存（断流或缺价留空）,导出于 2026-10-01")
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    func testBlankCellsForBrokenStreamAndUnpriced() {
        // 近 30 天断流:7/30 天、金额与活跃天数全部留空,单价缺价也留空
        let csv = ModelRankingCSVExport.makeCSV(
            rows: [row(3, model: "mystery-model", week: nil, month: nil,
                       usd: nil, activeDays: nil, price: "")],
            scopeTitle: "全部", sortTitle: "用量")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1], "3,Claude,mystery-model,524000000,62,,,,,")
    }

    func testPercentRoundsToInteger() {
        let csv = ModelRankingCSVExport.makeCSV(
            rows: [row(1, share: 0.3456)], scopeTitle: "近 7 天", sortTitle: "用量")
        // 34.56 → 35(rounded),与榜单行的 Int((share*100).rounded())% 同口径
        XCTAssertTrue(csv.split(separator: "\n")[1].hasPrefix("1,Claude,opus-5-5,524000000,35,"))
    }

    func testEscapingFollowsRFC4180() {
        XCTAssertEqual(ModelRankingCSVExport.escaped("plain"), "plain")
        XCTAssertEqual(ModelRankingCSVExport.escaped("a,b"), "\"a,b\"")
        XCTAssertEqual(ModelRankingCSVExport.escaped("say \"hi\""), "\"say \"\"hi\"\"\"")
        // 转义后的字段作为整列不会再破坏行结构(整行比对,
        // 引号内的逗号不拆列——裸按逗号切会切进引号字段)
        let csv = ModelRankingCSVExport.makeCSV(
            rows: [row(1, model: "model, \"quoted\"")],
            scopeTitle: "全部", sortTitle: "用量")
        XCTAssertEqual(
            csv.split(separator: "\n").map(String.init)[1],
            "1,Claude,\"model, \"\"quoted\"\"\",524000000,62,84000000,524000000,54.50,10,$3 / $15 /M")
    }

    func testSuggestedFilenameCarriesDate() {
        XCTAssertEqual(
            ModelRankingCSVExport.suggestedFilename(),
            "TokenMeter-models-\(DateUtil.today()).csv")
    }
}
