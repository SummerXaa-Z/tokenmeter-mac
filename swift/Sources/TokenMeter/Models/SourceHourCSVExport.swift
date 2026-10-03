import Foundation

// 今日分时卡导出 CSV：逐小时一行（0-23 全钟点照列，无用量为 0），
// 与四页共用分时图同口径。数字保持原始整数；来源页的小时归属口径
//（如 Qwen 按 Session 结束时间）由调用方以 note 原文带进口径行。
enum SourceHourCSVExport {
    static func makeCSV(
        source: HistorySource,
        bars: [SourceHourChart.Bar],
        note: String? = nil,
        todayKey: String = DateUtil.today()
    ) -> String {
        var lines: [[String]] = []
        lines.append(["小时", "Token"])
        let sorted = bars.sorted { $0.hour < $1.hour }
        for bar in sorted {
            lines.append([String(bar.hour), String(bar.tokens)])
        }
        if !sorted.isEmpty {
            lines.append(["合计", String(sorted.reduce(0) { $0 + $1.tokens })])
        }

        var notes: [String] = [
            "口径",
            "\(source.overviewName) · 今日逐时（与分时图同口径）",
        ]
        if let note, !note.isEmpty {
            notes.append(note)
        }
        notes.append("0-23 全钟点照列，无用量为 0（真实零）")
        notes.append("Token 为原始整数")
        notes.append("导出于 \(todayKey)")
        for text in notes {
            lines.append([ModelRankingCSVExport.escaped(text)])
        }
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func suggestedFilename(
        source: HistorySource,
        todayKey: String = DateUtil.today()
    ) -> String {
        let token = ModelRankingCSVExport.sanitizedNameToken(source.overviewName)
        return "TokenMeter-hours-\(token.isEmpty ? "source" : token)-\(todayKey).csv"
    }
}
