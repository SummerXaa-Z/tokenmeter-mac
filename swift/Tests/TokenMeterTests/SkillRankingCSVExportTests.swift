import XCTest
@testable import TokenMeter

final class SkillRankingCSVExportTests: XCTestCase {
    private func weeks(_ counts: [Int], firstWeekOf: String = "2026-07-13")
    -> [(weekOf: String, count: Int)]? {
        guard !counts.isEmpty else { return nil }
        guard let start = DateUtil.date(from: firstWeekOf) else { return nil }
        let calendar = Calendar.current
        return counts.enumerated().map { index, count in
            let date = calendar.date(byAdding: .day, value: index * 7, to: start) ?? start
            return (weekOf: DateUtil.key(date), count: count)
        }
    }

    private func row(
        _ rank: Int,
        skill: String = "frontend-design",
        count: Int = 12,
        share: Double = 0.75,
        sourceNote: String = "Claude 12 次、Codex 4 次",
        weekly: [(weekOf: String, count: Int)]? = nil
    ) -> SkillRankingCSVExport.Row {
        SkillRankingCSVExport.Row(
            rank: rank, skill: skill, invocationCount: count, sharePercent: share,
            sourceNote: sourceNote, weekly: weekly)
    }

    func testHeaderCarriesWeekLabelsFromFirstSeries() {
        // 首行有序列(3 周),列头即各周周一;断流行对齐补空
        let csv = SkillRankingCSVExport.makeCSV(
            rows: [
                row(1, weekly: weeks([2, 0, 4])),
                row(2, skill: "pdf", count: 3, share: 0.2,
                    sourceNote: "Copilot 3 次", weekly: nil),
            ],
            scopeTitle: "近 30 天",
            todayKey: "2026-10-01")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "名次,Skill,调用次数,占比%,来源拆解,7/13周,7/20周,7/27周")
        XCTAssertEqual(lines[1], "1,frontend-design,12,75,Claude 12 次、Codex 4 次,2,0,4")
        // 近 13 周窗口语义的 nil 在这里表现为整段周列留空,与列头对齐
        XCTAssertEqual(lines[2], "2,pdf,3,20,Copilot 3 次,,,")
        XCTAssertEqual(lines[3],
            "口径,范围 近 30 天,来源只认明确调用证据（普通消息提及不计入）,"
                + "周列为近 13 周逐周调用次数（周一锚定，旧→新，无调用留空）,导出于 2026-10-01")
        XCTAssertTrue(csv.hasSuffix("\n"))
    }

    func testAllRowsWithoutSeriesOmitWeekColumns() {
        // 全部断流:没有任何周列,只剩基础列
        let csv = SkillRankingCSVExport.makeCSV(
            rows: [row(1, weekly: nil)], scopeTitle: "全部")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "名次,Skill,调用次数,占比%,来源拆解")
        XCTAssertEqual(lines[1], "1,frontend-design,12,75,Claude 12 次、Codex 4 次")
    }

    func testEscapesSkillNameWithComma() {
        let csv = SkillRankingCSVExport.makeCSV(
            rows: [row(1, skill: "skill, \"quoted\"")], scopeTitle: "全部")
        XCTAssertEqual(
            csv.split(separator: "\n").map(String.init)[1],
            "1,\"skill, \"\"quoted\"\"\",12,75,Claude 12 次、Codex 4 次")
    }

    func testSuggestedFilenameCarriesDate() {
        XCTAssertEqual(
            SkillRankingCSVExport.suggestedFilename(),
            "TokenMeter-skills-\(DateUtil.today()).csv")
    }
}
