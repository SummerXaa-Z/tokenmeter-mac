import XCTest
@testable import TokenMeter

// OverviewRankingsCard 悬停说明行的拼串规则:近 7/30 天 Token、
// 30 天 API 等价(缺价明示)、活跃天数;近 30 天断流时引导进详情页。
final class RankingsHoverPreviewTests: XCTestCase {
    private func day(_ key: String, usd: Double = 0, tally: ModelTokenTally) -> CodingModelDetail.DayValue {
        CodingModelDetail.DayValue(date: key, usd: usd, tally: tally)
    }

    private func summary(
        tally: ModelTokenTally, days: [CodingModelDetail.DayValue], coverage: Double?
    ) -> CodingModelDetail.Summary {
        CodingModelDetail.Summary(
            source: .claude, model: "opus-5-5", tally: tally, days: days, coverage: coverage)
    }

    func testHoverPreviewTextCombinesWeekMonthCostAndActiveDays() {
        let monthTally = ModelTokenTally(input: 24_000_000, cached: 480_000_000, cacheWrite: 12_000_000, output: 8_000_000)
        let monthDays = (0..<30).map { offset in
            day(
                "2026-09-\(String(format: "%02d", max(1, 30 - offset)))",
                usd: offset == 0 ? 4.50 : 1.75,
                tally: offset == 0 ? .init(output: 80_000_000) : .init(output: 4_000_000))
        }
        let month = summary(tally: monthTally, days: monthDays, coverage: 0.999)
        let week = summary(
            tally: .init(cached: 4_000_000, output: 80_000_000),
            days: Array(monthDays.prefix(7)), coverage: 1)

        XCTAssertEqual(
            OverviewRankingsCard.hoverPreviewText(week: week, month: month),
            "近 7 天 84M · 近 30 天 524M · 30 天 API 等价 $55.25 · 活跃 30 天")
    }

    func testHoverPreviewTextMonthNilPointsToDetailPage() {
        XCTAssertEqual(
            OverviewRankingsCard.hoverPreviewText(week: nil, month: nil),
            "近 30 天无用量（该行来自更早历史），点进详情页看 90 天")
    }

    func testHoverPreviewTextWeekMissingCountsAsZero() {
        // 月内有量但最近 7 天断流:周窗 summary 为 nil,按 0 展示而不是误报整月无用量
        let month = summary(
            tally: .init(output: 96_000_000),
            days: [day("2026-09-03", usd: 3.20, tally: .init(output: 96_000_000))],
            coverage: nil)
        XCTAssertEqual(
            OverviewRankingsCard.hoverPreviewText(week: nil, month: month),
            "近 7 天 0 · 近 30 天 96M · 30 天 API 等价 $3.20 · 活跃 1 天")
    }

    func testHoverPreviewTextUnpricedMonthSaysSoInsteadOfZeroUSD() {
        let month = summary(
            tally: .init(output: 96_000_000),
            days: [day("2026-09-20", usd: 0, tally: .init(output: 96_000_000))],
            coverage: 0)
        XCTAssertEqual(
            OverviewRankingsCard.hoverPreviewText(
                week: .init(
                    source: .claude, model: "opus-5-5", tally: .init(output: 12_000_000),
                    days: [], coverage: 0),
                month: month),
            "近 7 天 12M · 近 30 天 96M · 30 天 API 等价缺价 · 活跃 1 天")
    }

    // MARK: - Skills 榜悬停说明行

    func testHoverSkillTextSplitsBySourceInGivenOrder() {
        // sources 已由模型层按次数降序排好,视图层只负责拼串
        let entry = PersonalSkillRankings.Entry(
            name: "frontend-design", invocationCount: 16, share: 0.84,
            sources: [
                .init(source: .claude, invocationCount: 12),
                .init(source: .codex, invocationCount: 4),
            ])
        XCTAssertEqual(
            OverviewRankingsCard.hoverSkillText(for: entry),
            "Claude 12 次 · Codex 4 次")
    }

    func testHoverSkillTextSingleSourceAndEmptySources() {
        let single = PersonalSkillRankings.Entry(
            name: "pdf", invocationCount: 3, share: 1,
            sources: [.init(source: .copilot, invocationCount: 3)])
        XCTAssertEqual(
            OverviewRankingsCard.hoverSkillText(for: single),
            "GitHub Copilot 3 次")

        let empty = PersonalSkillRankings.Entry(
            name: "ghost", invocationCount: 0, share: 0, sources: [])
        XCTAssertEqual(
            OverviewRankingsCard.hoverSkillText(for: empty),
            "该 Skill 暂无调用记录")
    }
}
