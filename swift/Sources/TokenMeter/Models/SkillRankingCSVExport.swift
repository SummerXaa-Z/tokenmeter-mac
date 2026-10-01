import Foundation

// Skills 榜 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 行序即榜单完整顺序（不只界面前 5）。来源拆解与榜内悬停同数据；
// 近 13 周逐周调用次数作为每周一列（周一锚定、旧→新），列头即该周
// 周一日期（如「9/14周」），取自首个有序列行的窗口——所有 Skill 的
// 13 周窗口都锚定同一个今天，列头天然一致；近 13 周无调用的行整段
// 留空（留空表示「没有这个口径的数字」，不是 0 次以外的其他含义）。
// 文本含逗号/引号时按 RFC 4180 转义（复用模型榜导出的转义）。
// 末尾附「口径」行：范围、来源判定与导出日期随文件自带。
enum SkillRankingCSVExport {
    struct Row {
        let rank: Int              // 1 起，调用方按榜单顺序给出
        let skill: String
        let invocationCount: Int   // 所选范围调用次数
        let sharePercent: Double   // 0...1，与榜单同源
        let sourceNote: String     // 如 "Claude 12 次、Codex 4 次"
        let weekly: [(weekOf: String, count: Int)]?   // 旧→新；nil = 近 13 周无调用
    }

    static func makeCSV(
        rows: [Row],
        scopeTitle: String,
        todayKey: String = DateUtil.today()
    ) -> String {
        // 周列头取自首个有序列的行;窗口锚定今天,所有行同一套周一期
        let weekLabels = rows.compactMap(\.weekly).first?
            .map { "\(Fmt.mmdd($0.weekOf))周" } ?? []
        var lines = [[String]]()
        lines.append(["名次", "Skill", "调用次数", "占比%", "来源拆解"] + weekLabels)
        for row in rows {
            let weekCells = row.weekly?.map { String($0.count) }
                ?? Array(repeating: "", count: weekLabels.count)
            lines.append([
                String(row.rank),
                escaped(row.skill),
                String(row.invocationCount),
                String(Int((row.sharePercent * 100).rounded())),
                escaped(row.sourceNote),
            ] + weekCells)
        }
        lines.append([
            "口径",
            escaped("范围 \(scopeTitle)"),
            "来源只认明确调用证据（普通消息提及不计入）",
            "周列为近 13 周逐周调用次数（周一锚定，旧→新，无调用留空）",
            "导出于 \(todayKey)",
        ])
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func escaped(_ field: String) -> String {
        ModelRankingCSVExport.escaped(field)
    }

    static func suggestedFilename() -> String {
        "TokenMeter-skills-\(DateUtil.today()).csv"
    }
}
