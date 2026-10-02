import XCTest
@testable import TokenMeter

// 图例 chip 悬停说明行的装配：范围内该来源合计 + API 等价文本
final class OverviewSeriesHoverTests: XCTestCase {
    private let totals: [(name: String, total: Int)] = [
        ("Claude", 412_000_000),
        ("Codex", 260_000_000),
        ("Gemini", 2_000_000),
    ]

    func testSummaryCarriesSeriesTotalAndAmount() {
        let summary = OverviewSeriesHover.summary(
            name: "Claude", seriesTotals: totals, amount: 8.4)
        XCTAssertEqual(summary?.label, "Claude · 范围内合计")
        XCTAssertEqual(summary?.total, 412_000_000)
        XCTAssertEqual(summary?.amountText, "$8.40")
    }

    func testSummaryOmitsAmountWhenAbsentOrZero() {
        // 无金额(缺价/断流/未配置)→ 不给金额文本,不冒充 $0
        XCTAssertNil(OverviewSeriesHover.summary(
            name: "Gemini", seriesTotals: totals, amount: nil)?.amountText)
        XCTAssertNil(OverviewSeriesHover.summary(
            name: "Gemini", seriesTotals: totals, amount: 0)?.amountText)
    }

    func testSummaryReturnsNilForUnknownSeries() {
        // 悬停的名字不在序列里(悬停态理论不发生)→ 整体 nil,说明行回落默认
        XCTAssertNil(OverviewSeriesHover.summary(
            name: "Cursor", seriesTotals: totals, amount: 1.0))
    }
}
