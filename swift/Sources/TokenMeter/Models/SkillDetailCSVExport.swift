import Foundation

// Skill 下钻页 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 行序即详情页近 13 周柱图（周一锚定、旧→新），逐周一行；无调用的周
// 照列——0 是真实零，与柱图的空柱对应。范围统计与来源拆解来自所点
// 榜单行的 Entry（与点击时所见完全一致），放进末尾「口径」行随文件
// 自带。文本含逗号/引号时按 RFC 4180 转义（复用模型榜导出的转义）。
enum SkillDetailCSVExport {
    static func makeCSV(
        entry: PersonalSkillRankings.Entry,
        weekly: [(weekOf: String, count: Int)],
        sourceNote: String,
        scopeTitle: String,
        todayKey: String = DateUtil.today()
    ) -> String {
        var lines = [[String]]()
        lines.append(["周(周一)", "调用次数"])
        for week in weekly {
            lines.append([week.weekOf, String(week.count)])
        }
        lines.append([
            "口径",
            escaped("Skill \(entry.name)"),
            escaped("范围 \(scopeTitle) 调用 \(Fmt.int(entry.invocationCount)) 次（占 Skills 榜 \(Int((entry.share * 100).rounded()))%）"),
            escaped("来源拆解 \(sourceNote)"),
            "周列为近 13 周逐周调用次数（周一锚定，旧→新，无调用的周计 0，本周进行中）",
            "来源只认明确调用证据（普通消息提及不计入）",
            "导出于 \(todayKey)",
        ])
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// 文件名：Skill 名净化为安全段（共享助手），空名回退通用名。
    static func suggestedFilename(skill: String) -> String {
        let safe = ModelRankingCSVExport.sanitizedNameToken(skill)
        return "TokenMeter-skill-\(safe.isEmpty ? "skill" : safe)-\(DateUtil.today()).csv"
    }

    private static func escaped(_ field: String) -> String {
        ModelRankingCSVExport.escaped(field)
    }
}
