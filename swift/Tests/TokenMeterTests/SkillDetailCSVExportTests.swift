import XCTest
@testable import TokenMeter

final class SkillDetailCSVExportTests: XCTestCase {
    private func entry(
        name: String = "pdf",
        count: Int = 42,
        share: Double = 0.62
    ) -> PersonalSkillRankings.Entry {
        PersonalSkillRankings.Entry(
            name: name,
            invocationCount: count,
            share: share,
            sources: [
                .init(source: .claude, invocationCount: 30),
                .init(source: .codex, invocationCount: 12),
            ])
    }

    func testHeaderAndWeeklyRowsKeepZeroWeeks() {
        let csv = SkillDetailCSVExport.makeCSV(
            entry: entry(),
            weekly: [
                ("2026-09-14", 5),
                ("2026-09-21", 0),   // 无调用的周照列,0 是真实零
                ("2026-09-28", 2),
            ],
            sourceNote: "Claude 30 次 · Codex 12 次",
            scopeTitle: "近 30 天",
            todayKey: "2026-10-02")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "周(周一),调用次数")
        XCTAssertEqual(lines[1], "2026-09-14,5")
        XCTAssertEqual(lines[2], "2026-09-21,0")
        XCTAssertEqual(lines[3], "2026-09-28,2")
    }

    func testFooterCarriesRangeSourceAndPipline() {
        let csv = SkillDetailCSVExport.makeCSV(
            entry: entry(name: "frontend,design", count: 16, share: 0.25),
            weekly: [("2026-09-28", 2)],
            sourceNote: "Claude 30 次 · Codex 12 次",
            scopeTitle: "近 30 天",
            todayKey: "2026-10-02")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        // 只有含半角逗号的字段（Skill 名）按 RFC 4180 加引号；全角标点不触发
        XCTAssertEqual(lines[2], "口径,"
            + "\"Skill frontend,design\","
            + "范围 近 30 天 调用 16 次（占 Skills 榜 25%）,"
            + "来源拆解 Claude 30 次 · Codex 12 次,"
            + "周列为近 13 周逐周调用次数（周一锚定，旧→新，无调用的周计 0，本周进行中）,"
            + "来源只认明确调用证据（普通消息提及不计入）,"
            + "导出于 2026-10-02")
    }

    func testEmptyWeeklyStillHasHeaderAndFooter() {
        let csv = SkillDetailCSVExport.makeCSV(
            entry: entry(),
            weekly: [],
            sourceNote: "Claude 30 次",
            scopeTitle: "全部",
            todayKey: "2026-10-02")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "周(周一),调用次数")
        XCTAssertTrue(lines[1].hasPrefix("口径,"))
    }

    func testSuggestedFilenameSanitizesSkillName() {
        // 常规名原样保留
        XCTAssertEqual(
            SkillDetailCSVExport.suggestedFilename(skill: "pdf"),
            "TokenMeter-skill-pdf-\(DateUtil.today()).csv")
        // 路径分隔符/空格/标点换连字符,连续的折叠为一个
        XCTAssertEqual(
            SkillDetailCSVExport.suggestedFilename(skill: "frontend/design v2!"),
            "TokenMeter-skill-frontend-design-v2-\(DateUtil.today()).csv")
        // 全部不安全或为空时回退通用名,不给 "TokenMeter-skill--日期"
        XCTAssertEqual(
            SkillDetailCSVExport.suggestedFilename(skill: "//"),
            "TokenMeter-skill-skill-\(DateUtil.today()).csv")
        XCTAssertEqual(
            SkillDetailCSVExport.suggestedFilename(skill: ""),
            "TokenMeter-skill-skill-\(DateUtil.today()).csv")
    }
}
