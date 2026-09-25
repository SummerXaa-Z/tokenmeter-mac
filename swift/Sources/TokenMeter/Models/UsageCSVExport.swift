import Foundation

// 用量历史 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 列固定为 日期 + Coding 来源（不含 DeepSeek 平台）+ Coding 合计 + 平台 Token
// + 平台费用；按日期升序，任何输入顺序都产出稳定结果。
enum UsageCSVExport {
    private static let codingColumns: [(source: HistorySource, title: String)] = [
        (.claude, "Claude"), (.codex, "Codex"), (.kimi, "Kimi"),
        (.opencode, "OpenCode"), (.gemini, "Gemini"), (.copilot, "Copilot"),
        (.qwen, "Qwen Code"), (.cursor, "Cursor"),
    ]

    static func makeCSV(_ days: [HistoryStore.DayPoint]) -> String {
        var lines = [[String]]()
        lines.append(["日期"]
            + codingColumns.map(\.title)
            + ["Coding 合计", "DeepSeek 平台", "平台费用(USD)"])
        for day in days.sorted(by: { $0.date < $1.date }) {
            let codingTotal = HistorySource.codingAgents.reduce(0) {
                $0 + (day.bySource[$1] ?? 0)
            }
            lines.append([day.date]
                + codingColumns.map { String(day.bySource[$0.source] ?? 0) }
                + [
                    String(codingTotal),
                    String(day.bySource[.deepseek] ?? 0),
                    String(format: "%.2f", day.cost),
                ])
        }
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func suggestedFilename() -> String {
        "TokenMeter-usage-\(DateUtil.today()).csv"
    }
}
