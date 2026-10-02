import Foundation

// 总览「周|近7天|月」环比卡导出 CSV：合计行 + 各来源行（本期/上期/环比），
// 行序与卡片一致（两期较大值降序）。环比 = (本期-上期)/上期，上期为 0
// （无基期）留空，不冒充 0%；数字保持原始整数。
enum PeriodCompareCSVExport {
    static func makeCSV(
        period: PeriodCompare.Period,
        this: [HistorySource: Int],
        last: [HistorySource: Int],
        todayKey: String = DateUtil.today()
    ) -> String {
        let rows = PeriodCompare.rows(this: this, last: last)
        let thisTotal = this.values.reduce(0, +)
        let lastTotal = last.values.reduce(0, +)

        var lines: [[String]] = []
        lines.append(["来源", "本期 Token", "上期 Token", "环比"])
        lines.append([
            "合计", String(thisTotal), String(lastTotal),
            changeText(this: thisTotal, last: lastTotal),
        ])
        for row in rows {
            lines.append([
                row.source.overviewName,
                String(row.this),
                String(row.last),
                changeText(this: row.this, last: row.last),
            ])
        }
        appendNotes(to: &lines, period: period, todayKey: todayKey)
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// 环比单元格：带符号百分比；无基期（上期为 0）留空
    private static func changeText(this: Int, last: Int) -> String {
        guard let change = PeriodCompare.change(this: this, last: last) else {
            return ""
        }
        return String(format: "%+.0f%%", change)
    }

    private static func appendNotes(
        to lines: inout [[String]],
        period: PeriodCompare.Period,
        todayKey: String
    ) {
        let notes: [String] = [
            "口径",
            "\(period.title)（\(period.footnote)）",
            "来源 = 已启用 Coding 来源，DeepSeek 平台账户不计入",
            "环比 = (本期 - 上期) / 上期；上期为 0（无基期）留空",
            "行序 = 两期较大值降序（合计行除外，与卡片一致）",
            "Token 为原始整数",
            "导出于 \(todayKey)",
        ]
        for note in notes {
            lines.append([ModelRankingCSVExport.escaped(note)])
        }
    }

    static func suggestedFilename(
        period: PeriodCompare.Period,
        todayKey: String = DateUtil.today()
    ) -> String {
        let slug: String
        switch period {
        case .week: slug = "week"
        case .rolling7: slug = "7d"
        case .month: slug = "month"
        }
        return "TokenMeter-compare-\(slug)-\(todayKey).csv"
    }
}
