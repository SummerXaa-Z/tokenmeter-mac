import XCTest
@testable import TokenMeter

// Skill 迷你条的近 N 周聚合:周一锚定分桶、跨源合并、实时整天权威覆盖、
// 空周计 0 定长输出、窗口外不计、全空返回 nil。
final class SkillUsageTrendTests: XCTestCase {
    private func day(
        _ date: String, source: HistorySource, skills: [String: Int]
    ) -> ModelUsageDay {
        ModelUsageDay(date: date, bySource: [source: SourceDayDetail(skills: skills)])
    }

    func testWeeklyCountsMergeSourcesAnchorMondaysAndPadEmptyWeeks() {
        // 窗口:2026-07-06(周一)起 13 周,本周一 2026-09-28,今天 10-01(周四)
        let series = SkillUsageTrend.weeklyCounts(
            name: "pdf",
            weeks: 13,
            liveSkills: [.copilot: ["2026-09-29": ["pdf": 1]]],
            persisted: [
                day("2026-09-28", source: .claude, skills: ["pdf": 2]),
                day("2026-09-28", source: .codex, skills: ["pdf": 3]),
                day("2026-09-24", source: .claude, skills: ["pdf": 4]),
                // 窗口起点之前(上周日):不计入
                day("2026-07-05", source: .claude, skills: ["pdf": 99]),
            ],
            todayKey: "2026-10-01")
        XCTAssertNotNil(series)
        XCTAssertEqual(series?.count, 13)
        // 首周是窗口起点周一,空周计 0
        XCTAssertEqual(series?.first?.weekOf, "2026-07-06")
        XCTAssertEqual(series?.first?.count, 0)
        // 倒数第二周(09-21 起)吸收 09-24 的 4 次
        XCTAssertEqual(series?.dropLast().last?.weekOf, "2026-09-21")
        XCTAssertEqual(series?.dropLast().last?.count, 4)
        // 本周(09-28 起)= 留存 2+3 + 实时 1,三天都落进同一周
        XCTAssertEqual(series?.last?.weekOf, "2026-09-28")
        XCTAssertEqual(series?.last?.count, 6)
    }

    func testWeeklyCountsLiveDayOverridesPersistedSameDayPerSource() {
        // 09-30 留存 pdf 5;实时 claude 当天窗口里只有别的 Skill
        // → 该来源当天 pdf 覆盖为 0(不叠加留存旧值);两周窗口内
        // pdf 全部归零 → 断流语义返回 nil(不画迷你条)
        XCTAssertNil(SkillUsageTrend.weeklyCounts(
            name: "pdf",
            weeks: 2,
            liveSkills: [.claude: ["2026-09-30": ["other-skill": 7]]],
            persisted: [day("2026-09-30", source: .claude, skills: ["pdf": 5])],
            todayKey: "2026-10-01"))
        // 该天另一来源不受 claude 覆盖影响:codex 留存 4 照算
        let mixed = SkillUsageTrend.weeklyCounts(
            name: "pdf",
            weeks: 2,
            liveSkills: [.claude: ["2026-09-30": ["other-skill": 7]]],
            persisted: [
                day("2026-09-30", source: .claude, skills: ["pdf": 5]),
                day("2026-09-30", source: .codex, skills: ["pdf": 4]),
            ],
            todayKey: "2026-10-01")
        XCTAssertEqual(mixed?.last?.weekOf, "2026-09-28")
        XCTAssertEqual(mixed?.last?.count, 4)
    }

    func testWeeklyCountsReturnsNilWhenWindowEmpty() {
        XCTAssertNil(SkillUsageTrend.weeklyCounts(
            name: "ghost",
            weeks: 4,
            liveSkills: [.claude: ["2026-09-30": ["pdf": 1]]],
            persisted: [],
            todayKey: "2026-10-01"))
        XCTAssertNil(SkillUsageTrend.weeklyCounts(
            name: "pdf", weeks: 0, liveSkills: [:], persisted: [], todayKey: "2026-10-01"))
    }

    func testSkillWeekTextFormatsWeekLabelAndCount() {
        XCTAssertEqual(OverviewRankingsCard.skillWeekText(weekOf: "2026-09-14", count: 8), "9/14周 · 8 次")
        XCTAssertEqual(OverviewRankingsCard.skillWeekText(weekOf: "2026-09-14", count: 0), "9/14周 · 无调用")
    }
}
