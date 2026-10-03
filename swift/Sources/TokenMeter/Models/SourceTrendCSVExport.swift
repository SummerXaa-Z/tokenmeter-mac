import Foundation

// 来源页 7|30 天趋势卡导出 CSV：逐日一行，Token 分量各成一列（与图例
// 同名同序），附星期与合计。该卡为七个来源页共用组件，此处一处实现
// 全库受益。分量名按各来源展示习惯折叠（与 SourceTrendCard.parts 同
// 口径），口径行自带折叠说明；数字保持原始整数，补零时间轴的无用量
// 天照列 0（真实零）。
enum SourceTrendCSVExport {
    static func makeCSV(
        source: HistorySource,
        spanDays: Int,
        days: [SourceTrendCard.Day],
        todayKey: String = DateUtil.today()
    ) -> String {
        // 分量列：与图例同名同序（补零后每天分量结构一致，取首日即可）
        let partNames = days.first?.parts.map(\.name) ?? []

        var lines: [[String]] = []
        lines.append(["日期", "星期"] + partNames + ["合计"])
        for day in days {
            lines.append(row(for: day, partNames: partNames))
        }
        if !days.isEmpty {
            lines.append(totalRow(days: days, partNames: partNames))
        }
        appendNotes(
            to: &lines, source: source, spanDays: spanDays, todayKey: todayKey)
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// 单日行：日期 + 星期 + 各分量（缺分量列 0）+ 合计
    private static func row(
        for day: SourceTrendCard.Day, partNames: [String]
    ) -> [String] {
        var cells = [day.date, weekday(of: day.date)]
        for name in partNames {
            cells.append(String(day.parts.first { $0.name == name }?.value ?? 0))
        }
        let total = day.parts.reduce(0) { $0 + $1.value }
        cells.append(String(total))
        return cells
    }

    /// 合计行：各分量列求和 + 总合计
    private static func totalRow(
        days: [SourceTrendCard.Day], partNames: [String]
    ) -> [String] {
        var cells = ["合计", ""]
        for name in partNames {
            let sum = days.reduce(0) { sum, day in
                sum + (day.parts.first { $0.name == name }?.value ?? 0)
            }
            cells.append(String(sum))
        }
        let total = days.reduce(0) { sum, day in
            sum + day.parts.reduce(0) { $0 + $1.value }
        }
        cells.append(String(total))
        return cells
    }

    /// 日期键 → 周几（与热力图/周报同一写法）；非法日期留空
    private static func weekday(of dateKey: String) -> String {
        guard let date = DateUtil.date(from: dateKey) else { return "" }
        return HeatmapCSVExport.weekdayLabel(
            Calendar.current.component(.weekday, from: date))
    }

    private static func appendNotes(
        to lines: inout [[String]],
        source: HistorySource,
        spanDays: Int,
        todayKey: String
    ) {
        var notes: [String] = [
            "口径",
            "\(source.overviewName) · 近 \(spanDays) 天（与来源页趋势图同档同桶）",
        ]
        switch source {
        case .codex:
            notes.append("输出 = 输出 + 推理（Codex 惯例，与图例一致）")
        case .gemini, .qwen:
            notes.append("推理单列（与图例一致）")
        case .claude, .kimi, .opencode, .copilot:
            notes.append("推理并入输出（与图例一致）")
        case .deepseek, .cursor:
            break   // 平台账户/订阅聚合无此卡，理论不可达
        }
        notes.append(spanDays == 7
            ? "7 天档来自各页实时采集拼装"
            : "30 天档来自本机按天留存，实时明细覆盖同一天")
        notes.append("补零时间轴：无用量日照列 0（真实零）")
        notes.append("Token 为原始整数")
        notes.append("导出于 \(todayKey)")
        for note in notes {
            lines.append([ModelRankingCSVExport.escaped(note)])
        }
    }

    /// 单系列档（Cursor 历史趋势卡）：按日合计、无分量列——Cursor 只有
    /// 订阅周期聚合，没有逐请求分量，不凑不存在的口径。
    static func makeSingleSeriesCSV(
        source: HistorySource,
        spanDays: Int,
        days: [(date: String, tokens: Int)],
        todayKey: String = DateUtil.today()
    ) -> String {
        var lines: [[String]] = []
        lines.append(["日期", "星期", "Token"])
        let sorted = days.sorted { $0.date < $1.date }
        for day in sorted {
            lines.append([day.date, weekday(of: day.date), String(day.tokens)])
        }
        if !sorted.isEmpty {
            let total = sorted.reduce(0) { $0 + $1.tokens }
            lines.append(["合计", "", String(total)])
        }
        appendSingleSeriesNotes(
            to: &lines, source: source, spanDays: spanDays, todayKey: todayKey)
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func appendSingleSeriesNotes(
        to lines: inout [[String]],
        source: HistorySource,
        spanDays: Int,
        todayKey: String
    ) {
        let notes: [String] = [
            "口径",
            "\(source.overviewName) · 近 \(spanDays) 天（与来源页趋势卡同档）",
            "按日合计，来自本机按天历史（Cursor 仅有订阅周期聚合，无逐请求分量）",
            "补零时间轴：无用量日照列 0（真实零）",
            "Token 为原始整数",
            "导出于 \(todayKey)",
        ]
        for note in notes {
            lines.append([ModelRankingCSVExport.escaped(note)])
        }
    }

    static func suggestedFilename(
        source: HistorySource,
        spanDays: Int,
        todayKey: String = DateUtil.today()
    ) -> String {
        let token = ModelRankingCSVExport.sanitizedNameToken(source.overviewName)
        return "TokenMeter-trend-\(token.isEmpty ? "source" : token)-\(spanDays)d-\(todayKey).csv"
    }
}
