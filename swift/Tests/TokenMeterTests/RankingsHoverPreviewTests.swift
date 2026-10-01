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

    // MARK: - 迷你趋势柱布局

    func testSparklineBarsNormalizePeakFloorZeroesAndSplitWidth() {
        let bars = OverviewRankingsCard.sparklineBars(
            values: [0, 5, 10, 0, 7], width: 46, height: 14)
        XCTAssertEqual(bars.count, 5)
        // 5 柱 4 缝(0.5):每柱 (46 - 2) / 5 = 8.8
        XCTAssertEqual(bars[0].width, 8.8, accuracy: 0.01)
        XCTAssertEqual(bars[2].minX, 2 * 9.3, accuracy: 0.01)
        // 峰值满高、底对齐
        XCTAssertEqual(bars[2].height, 14, accuracy: 0.01)
        XCTAssertEqual(bars[2].minY, 0)
        // 零值零高(贴底的空矩形)
        XCTAssertEqual(bars[0].height, 0)
        XCTAssertEqual(bars[0].minY, 14)
        // 非零低值保底 1.5pt 可见:5/10 ≈ 7 → 7 不触发保底,
        // 但全同值序列里也不断柱
        XCTAssertEqual(bars[1].height, 7, accuracy: 0.01)
        XCTAssertEqual(bars[4].height, 9.8, accuracy: 0.01)
    }

    func testSparklineBarsFloorMinimumHeightAndEdgeCases() {
        // 峰值 1000、低值 1:1/1000 × 14 < 1.5 → 保底 1.5
        let bars = OverviewRankingsCard.sparklineBars(
            values: [1000, 1], width: 10, height: 14)
        XCTAssertEqual(bars[1].height, 1.5, accuracy: 0.01)
        // 全零序列:峰值按 1 兜底,柱高 0
        let flat = OverviewRankingsCard.sparklineBars(
            values: [0, 0, 0], width: 30, height: 14)
        XCTAssertTrue(flat.allSatisfy { $0.height == 0 })
        // 空序列 / 非正尺寸:空返回
        XCTAssertTrue(OverviewRankingsCard.sparklineBars(
            values: [], width: 44, height: 14).isEmpty)
        XCTAssertTrue(OverviewRankingsCard.sparklineBars(
            values: [1, 2], width: 0, height: 14).isEmpty)
    }

    // MARK: - 迷你柱单日悬停

    func testSparklineIndexMapsPointerXToBarAndClampsEdges() {
        // 30 柱宽 44:barWidth = (44 - 14.5)/30 ≈ 0.9833,stride ≈ 1.4833
        XCTAssertEqual(OverviewRankingsCard.sparklineIndex(atX: 0, count: 30, width: 44), 0)
        XCTAssertEqual(OverviewRankingsCard.sparklineIndex(atX: 1.5, count: 30, width: 44), 1)
        // 右端并入末柱,越界返回 nil
        XCTAssertEqual(OverviewRankingsCard.sparklineIndex(atX: 43.9, count: 30, width: 44), 29)
        XCTAssertEqual(OverviewRankingsCard.sparklineIndex(atX: 44, count: 30, width: 44), 29)
        XCTAssertNil(OverviewRankingsCard.sparklineIndex(atX: -0.1, count: 30, width: 44))
        XCTAssertNil(OverviewRankingsCard.sparklineIndex(atX: 44.1, count: 30, width: 44))
        XCTAssertNil(OverviewRankingsCard.sparklineIndex(atX: 10, count: 0, width: 44))
    }

    func testSparklineDayTextFormatsDateWeekdayAndTokens() {
        // 2026-09-26 是周六(分隔符与悬停说明行同款 " · ")
        XCTAssertEqual(
            OverviewRankingsCard.sparklineDayText(date: "2026-09-26", tokens: 36_000_000),
            "9/26（周六） · 36M")
        XCTAssertEqual(
            OverviewRankingsCard.sparklineDayText(date: "2026-10-01", tokens: 0),
            "10/1（周四） · 无用量")
    }

    // MARK: - 模型榜排序

    private func modelEntry(_ model: String, tokens: Int) -> PersonalUsageRankings.ModelEntry {
        PersonalUsageRankings.ModelEntry(
            source: .claude, model: model, totalTokens: tokens, share: 0.5)
    }

    func testSortedBySortValueDescendingStableAndFloor() {
        let models = [
            modelEntry("opus-5-5", tokens: 524),
            modelEntry("mystery-model", tokens: 96),
            modelEntry("gpt-5.4", tokens: 86),
        ]
        // 降序重排:近 7 天 gpt 登顶、opus 断流沉底
        let byWeek = OverviewRankingsCard.sortedBySortValue(models) { entry in
            entry.model == "gpt-5.4" ? 84.0 : (entry.model == "mystery-model" ? 40.0 : 0)
        }
        XCTAssertEqual(byWeek.map(\.model), ["gpt-5.4", "mystery-model", "opus-5-5"])
        // 键相等保持原顺序(稳定排序)
        let ties = OverviewRankingsCard.sortedBySortValue(models) { _ in 3.0 }
        XCTAssertEqual(ties.map(\.model), ["opus-5-5", "mystery-model", "gpt-5.4"])
        // 混合相等键:有值的在前,同值内保持原序
        let mixed = OverviewRankingsCard.sortedBySortValue(models) { entry in
            entry.model == "mystery-model" ? 10.0 : 0
        }
        XCTAssertEqual(mixed.map(\.model), ["mystery-model", "opus-5-5", "gpt-5.4"])
    }
}
