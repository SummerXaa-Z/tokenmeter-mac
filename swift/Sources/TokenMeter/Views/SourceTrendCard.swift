import SwiftUI
import Charts

// 来源页共用的 7|30 天 Token 堆叠柱图。7 天档由各页从自己的采集结果
// 拼装分量（与各自原有口径一致，实时重扫）；30 天档取本机按天留存，
// 实时 dayModels 覆盖同一天（与 API 等价卡同合并口径，不叠加），
// 分量按各来源的展示习惯折叠（Codex 无缓存写入、Gemini/Qwen 推理单列、
// 其余推理并入输出），最近 30 个自然日补零成完整时间轴。
// 悬停说明行的当日金额与所选档窗口同宽（7/30 天逐日重算，缺价不计入）。
struct SourceTrendCard: View {
    struct Day: Identifiable {
        let date: String     // yyyy-MM-dd
        let parts: [(name: String, value: Int, color: Color)]
        var id: String { date }
    }

    enum Span: Int, CaseIterable {
        case week = 7
        case month = 30

        var title: String { self == .week ? "7天" : "30天" }
    }

    let source: HistorySource
    let weekDays: [Day]
    let liveDayModels: [String: [String: ModelTokenTally]]?
    @State private var span: Span = .week
    @State private var hover: String?

    var body: some View {
        let days = span == .week ? weekDays : Self.monthDays(
            source: source, liveDayModels: liveDayModels)
        // 扁平化成 (日期, 类型, 数值):Chart 里嵌套 ForEach 的类型推断不稳
        let marks = days.flatMap { day in
            day.parts.map { part in
                (label: Fmt.mmdd(day.date), name: part.name, value: part.value)
            }
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("最近 \(span.rawValue) 天 Token", systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("范围", selection: $span) {
                        ForEach(SourceTrendCard.Span.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 104)
                }
                ChartHover.caption(
                    hover: hover,
                    amountFor: SourceHoverAmount.make(
                        source: source, liveDayModels: liveDayModels,
                        days: days.map(\.date), windowDays: span.rawValue),
                    buckets: days.map { day in
                        (
                            label: Fmt.mmdd(day.date),
                            total: day.parts.reduce(0) { $0 + $1.value },
                            parts: day.parts
                        )
                    })
                Chart {
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        BarMark(
                            x: .value("日期", mark.label),
                            y: .value("Token", mark.value))
                            .foregroundStyle(by: .value("类型", mark.name))
                    }
                    HoverDateRule(date: hover)
                }
                .chartXSelection(value: $hover)
                .chartForegroundStyleScale(Self.scale(for: source))
                .chartLegend(position: .bottom, spacing: 4)
                .tokenYAxis()
                .frame(height: 150)
            }
        }
    }

    /// 各来源的图例配色（7|30 天档同款）：与各页原 7 天图一致。
    private static func scale(for source: HistorySource) -> KeyValuePairs<String, Color> {
        switch source {
        case .codex:
            return [
                "缓存输入": Theme.hit, "新输入": Theme.input, "输出": Theme.response,
            ]
        case .gemini, .qwen:
            return [
                "缓存读取": Theme.hit, "新输入": Theme.input,
                "输出": Theme.response, "推理": Theme.miss,
            ]
        case .claude, .kimi, .opencode, .copilot:
            return [
                "缓存读取": Theme.hit, "缓存写入": Theme.miss,
                "新输入": Theme.input, "输出": Theme.response,
            ]
        case .deepseek, .cursor:
            return [:]
        }
    }

    /// 30 天档的逐日分量：留存按天明细按日汇总成单条五类 tally，实时
    /// dayModels 覆盖同一天（空明细清掉该天），再按来源习惯折叠成分量。
    /// 最近 30 个自然日补零，时间轴完整、图例稳定。
    static func monthDays(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current,
        windowDays: Int = Span.month.rawValue
    ) -> [Day] {
        guard let today = DateUtil.date(from: todayKey) else { return [] }
        let todayStart = calendar.startOfDay(for: today)
        var keys: [String] = []
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart)
            else { return [] }
            keys.append(DateUtil.key(date))
        }
        let window = Set(keys)

        var byDate: [String: ModelTokenTally] = [:]
        for day in persisted
        where window.contains(day.date) && ModelUsageHistoryStore.isDateKey(day.date) {
            for (_, tally) in day.bySource[source]?.models ?? [:] where !tally.isEmpty {
                byDate[day.date, default: ModelTokenTally()] += tally
            }
        }
        for (date, models) in liveDayModels ?? [:] where window.contains(date) {
            if let nonEmpty = ModelTokenTally.nonEmpty(models) {
                var sum = ModelTokenTally()
                for tally in nonEmpty.values { sum += tally }
                byDate[date] = sum
            } else {
                byDate.removeValue(forKey: date)   // 实时确认无明细:清掉留存旧值
            }
        }
        return keys.map { date in
            Day(date: date, parts: parts(source, of: byDate[date] ?? ModelTokenTally()))
        }
    }

    /// 各来源 30 天档的分量折叠：与各自 7 天图的图例一致。
    static func parts(
        _ source: HistorySource, of tally: ModelTokenTally
    ) -> [(name: String, value: Int, color: Color)] {
        switch source {
        case .codex:
            return [
                ("缓存输入", tally.cached, Theme.hit),
                ("新输入", tally.input, Theme.input),
                ("输出", tally.output + tally.reasoning, Theme.response),
            ]
        case .gemini, .qwen:
            return [
                ("缓存读取", tally.cached, Theme.hit),
                ("新输入", tally.input, Theme.input),
                ("输出", tally.output, Theme.response),
                ("推理", tally.reasoning, Theme.miss),
            ]
        case .claude, .kimi, .opencode, .copilot:
            return [
                ("缓存读取", tally.cached, Theme.hit),
                ("缓存写入", tally.cacheWrite, Theme.miss),
                ("新输入", tally.input, Theme.input),
                ("输出", tally.output + tally.reasoning, Theme.response),
            ]
        case .deepseek, .cursor:
            return []   // 平台账户/订阅聚合，无按天模型明细页
        }
    }
}
