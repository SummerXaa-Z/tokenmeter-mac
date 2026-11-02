import SwiftUI
import Charts
import AppKit

// 来源页共用的 Token 堆叠柱图，进入时精确保留 1D/7D/30D/全部范围。
// 未指定入口范围的独立夹具兼容 7|30 天切换，7 天档从采集结果
// 拼装分量（与各自原有口径一致，实时重扫）；30 天档取本机按天留存，
// 实时 dayModels 覆盖同一天（与 API 等价卡同合并口径，不叠加），
// 分量按各来源的展示习惯折叠（Codex 无缓存写入、Gemini/Qwen 推理单列、
// 其余推理并入输出），最近 30 个自然日补零成完整时间轴。
// 悬停说明行的当日金额与所选档窗口同宽（7/30 天逐日重算，缺价不计入）。
struct SourceTrendCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.usageNow) private var now
    @EnvironmentObject private var historyReader: HistorySnapshotReader
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
    var initialRange: UsageHistoryRange? = nil
    // 渲染夹具:注入固定的导出反馈文案(保存面板无法离屏模拟)
    var previewExportStatus: String? = nil
    @State private var span: Span = .week
    @State private var hover: String?
    // 导出完成后的行内反馈(「已导出 <文件名> · 时刻」)
    @State private var exportStatus: String?
    private var activeRange: UsageHistoryRange { initialRange ?? (span == .week ? .week : .month) }

    var body: some View {
        let history = historyReader.dashboardHistory(state: state, todayKey: DateUtil.key(now))
        let range = activeRange
        let today = DateUtil.key(now)
        let daily = initialRange == nil
            ? (span == .week ? weekDays : Self.monthDays(source: source, liveDayModels: liveDayModels,
                                                       persisted: history.models, todayKey: today))
            : Self.rangeDays(source: source, range: range, persisted: history.models,
                             dailyHistory: history.daily, todayKey: today)
        let granularity = range.trendGranularity(historyDayCount: daily.count)
        let days = Self.chartBuckets(daily, granularity: granularity)
        let hours = hourlyValues(on: today)
        let amounts = SourceAPICost.dailyValues(source: source, liveDayModels: initialRange == nil ? liveDayModels : nil, persisted: history.models,
                                               todayKey: today, windowDays: max(daily.count, 1))
        let bucketAmounts = amounts.reduce(into: [String: Double]()) { result, entry in
            result[Self.bucketKey(entry.key, granularity: granularity), default: 0] += entry.value
        }
        // 扁平化成 (日期, 类型, 数值):Chart 里嵌套 ForEach 的类型推断不稳
        let marks = days.flatMap { day in
            day.parts.map { part in
                (date: day.date, name: part.name, value: part.value)
            }
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(range.scopeTitle) Token · \(granularity.rawValue)", systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if initialRange == nil {
                      Picker("范围", selection: $span) {
                        ForEach(SourceTrendCard.Span.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 104)
                    }
                    // 导出当前档逐日分量 CSV(与图例同列,附口径行);
                    // 七页共用此卡,一处加上全部来源页受益
                    DashboardExportButton(help: "导出当前范围趋势 CSV（与图同桶，附范围和粒度）",
                                          disabled: !historyReader.canUseSnapshot || (range == .day ? hours == nil : Self.isEmpty(days))) {
                        exportCSV(days, hours: hours, granularity: granularity)
                    }
                }
                if range == .day {
                    if let amount = amounts[today] {
                        Text("今日等价合计 \(Fmt.usd(amount))（已计价部分，不是逐时金额）")
                            .font(Theme.detailFont).foregroundStyle(.secondary)
                    }
                    if let hours {
                        SourceHourChart(bars: (0..<24).map { .init(hour: $0, tokens: hours[$0] ?? 0) }, color: source.overviewColor)
                    } else {
                        ChartHover.emptyState(message: "今日分时尚不可确认", hint: "没有可验证的小时明细，不把日汇总平均摊分", minHeight: 114)
                    }
                } else if Self.isEmpty(days) {
                    // 零数据不画全零柱:统一空态占住图高,切 7|30 天档可恢复
                    ChartHover.emptyState(
                        message: "\(range.scopeTitle)暂无 Token 记录",
                        hint: "该工具产生用量后自动累积",
                        minHeight: 150)
                } else {
                    if let active = days.first(where: { $0.date == hover }) ?? days.last {
                        ChartHoverCaption(label: Self.bucketLabel(active.date, granularity: granularity),
                                          total: active.parts.reduce(0) { $0 + $1.value }, parts: active.parts,
                                          amountText: bucketAmounts[active.date].map { "已计价等价 \(Fmt.usd($0))" })
                    }
                    Chart {
                        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                            BarMark(
                                x: .value("日期", mark.date),
                                y: .value("Token", mark.value))
                                .foregroundStyle(by: .value("类型", mark.name))
                        }
                        HoverDateRule(date: hover)
                    }
                    .chartXSelection(value: $hover)
                    .chartForegroundStyleScale(Self.scale(for: source))
                    .chartLegend(position: .bottom, spacing: 4)
                    .tokenYAxis()
                    .dateXAxis(labels: Dictionary(uniqueKeysWithValues: days.map { ($0.date, Self.bucketLabel($0.date, granularity: granularity)) }))
                    .frame(height: 150)
                }
                if initialRange != nil, range == .all {
                    Text("全部指本机已留存历史；较长历史按周或月汇总。未归因部分只有总量，不推测缓存或输出分量。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
                // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    /// 导出当前档（7|30 天）逐日分量 CSV：分量列与图例同名同序、补零日
    /// 照列 0，附来源与折叠口径行。保存面板流程与全库其他导出同款，
    /// 写盘失败弹系统错误框。
    private func exportCSV(_ days: [Day], hours: [Int: Int]?, granularity: UsageTrendGranularity) {
        guard historyReader.canUseSnapshot else {
            exportStatus = historyReader.unavailableMessage
            return
        }
        let today = DateUtil.key(now)
        let range = activeRange
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出趋势 CSV",
            filename: SourceTrendCSVExport.suggestedFilename(
                source: source, spanDays: range.rawValue, todayKey: today, scopeTitle: initialRange.map(\.tabTitle))
        ) {
            if range == .day {
                return SourceTrendCSVExport.makeSingleSeriesCSV(
                    source: source, spanDays: 1,
                    days: (0..<24).map { (date: String(format: "%@T%02d", today, $0), tokens: hours?[$0] ?? 0) },
                    todayKey: today, scopeTitle: range.scopeTitle, granularity: .hour)
            }
            return SourceTrendCSVExport.makeCSV(
                source: source, spanDays: range.rawValue, days: days,
                todayKey: today, scopeTitle: initialRange.map(\.scopeTitle), granularity: granularity
            )
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }

    private func hourlyValues(on date: String) -> [Int: Int]? {
        switch source {
        case .claude: return state.claude.result?.hourlyTokens(on: date)
        case .codex: return state.codex.result?.hourlyTokens(on: date)
        case .kimi: return state.kimi.result?.hourlyTokens(on: date)
        case .opencode: return state.opencode.result?.hourlyTokens(on: date)
        case .gemini: return state.gemini.result?.hourlyTokens(on: date)
        case .qwen: return state.qwen.result?.hourlyTokens(on: date)
        case .copilot, .cursor, .deepseek: return nil
        }
    }

    static func rangeDays(source: HistorySource, range: UsageHistoryRange, persisted: [ModelUsageDay],
                          dailyHistory: [HistoryStore.DayPoint], todayKey: String, calendar: Calendar = .current) -> [Day] {
        guard let today = DateUtil.date(from: todayKey) else { return [] }
        let detailDates = persisted.filter { $0.date <= todayKey && ModelUsageHistoryStore.isDateKey($0.date) && $0.bySource[source] != nil }.map(\.date)
        let totalDates = dailyHistory.filter { $0.date <= todayKey && ModelUsageHistoryStore.isDateKey($0.date) && ($0.bySource[source] ?? 0) > 0 }.map(\.date)
        guard let first = range.fixedDayCount.flatMap({ calendar.date(byAdding: .day, value: 1 - $0, to: today) })
            ?? (detailDates + totalDates).min().flatMap(DateUtil.date(from:)) else { return [] }
        let count = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        var days = monthDays(source: source, liveDayModels: nil, persisted: persisted, todayKey: todayKey,
                             calendar: calendar, windowDays: count)
        let totals = dailyHistory.reduce(into: [String: Int]()) { $0[$1.date] = max($1.bySource[source] ?? 0, 0) }
        for index in days.indices {
            let known = days[index].parts.reduce(0) { $0 + $1.value }
            let missing = max((totals[days[index].date] ?? 0) - known, 0)
            days[index] = Day(date: days[index].date, parts: days[index].parts + [("未归因", missing, Color.secondary)])
        }
        return days
    }

    static func chartBuckets(_ days: [Day], granularity: UsageTrendGranularity) -> [Day] {
        guard granularity == .week || granularity == .month else { return days }
        var buckets: [String: [String: (value: Int, color: Color)]] = [:]
        var order: [String] = []
        for day in days {
            let key = bucketKey(day.date, granularity: granularity)
            for part in day.parts {
                if !order.contains(part.name) { order.append(part.name) }
                let old = buckets[key, default: [:]][part.name]?.value ?? 0
                buckets[key, default: [:]][part.name] = (old + part.value, part.color)
            }
        }
        return buckets.keys.sorted().map { key in
            Day(date: key, parts: order.map { ($0, buckets[key]?[$0]?.value ?? 0, buckets[key]?[$0]?.color ?? .secondary) })
        }
    }

    static func bucketLabel(_ key: String, granularity: UsageTrendGranularity) -> String {
        granularity == .month ? Fmt.ym(key) : (granularity == .week ? "\(Fmt.mmdd(key))周" : Fmt.mmdd(key))
    }

    static func bucketKey(_ key: String, granularity: UsageTrendGranularity) -> String {
        guard granularity == .week || granularity == .month, let date = DateUtil.date(from: key) else { return key }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = Calendar.current.timeZone
        return DateUtil.key(calendar.dateInterval(of: granularity == .week ? .weekOfYear : .month, for: date)?.start ?? date)
    }

    /// 当前档是否整窗零用量(补零的时间轴全为 0)
    static func isEmpty(_ days: [Day]) -> Bool {
        days.allSatisfy { day in day.parts.reduce(0) { $0 + $1.value } == 0 }
    }

    /// 各来源的图例配色（7|30 天档同款）：与各页原 7 天图一致。
    private static func scale(for source: HistorySource) -> KeyValuePairs<String, Color> {
        switch source {
        case .codex:
            return [
                "缓存输入": Theme.hit, "新输入": Theme.input, "输出": Theme.response, "未归因": .secondary,
            ]
        case .gemini, .qwen:
            return [
                "缓存读取": Theme.hit, "新输入": Theme.input,
                "输出": Theme.response, "推理": Theme.miss, "未归因": .secondary,
            ]
        case .claude, .kimi, .opencode, .copilot:
            return [
                "缓存读取": Theme.hit, "缓存写入": Theme.miss,
                "新输入": Theme.input, "输出": Theme.response, "未归因": .secondary,
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
        persisted: [ModelUsageDay] = [],
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
