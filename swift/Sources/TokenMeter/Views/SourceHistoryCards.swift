import SwiftUI
import Charts
import AppKit

// 来源页通用的历史分析卡。消费视图树共享的按天历史快照，不依赖
// 各来源的实时采集——工具未运行、本地数据暂时缺失时历史对比依然可见,
// 与"数据路径消失不抹掉已积累历史"的既有承诺一致。从未有过记录时整卡隐藏。

// 单来源周期环比:周|近7天|月 三档(与总览环比卡同口径),下挂一行
// 今日 vs 近 7 天日均的滚动参照。Claude 页保留更细的缓存拆解周趋势,不用此卡。
// body 不访问磁盘；实际加载由 RootView 的 revision reader 执行，渲染夹具注入快照。
struct SourceTodayConfirmation: Equatable {
    enum Phase: Equatable { case confirmed, lastGood, unknown }
    let tokens: Int?
    let phase: Phase
    var canCompare: Bool { phase == .confirmed }

    init(liveTokens: Int?, recordedTokens: Int?, presentation: SourceCollectionPresentation) {
        tokens = liveTokens.map { max($0, 0) } ?? recordedTokens.map { max($0, 0) }
        if presentation.error == nil, !presentation.loading, liveTokens != nil {
            phase = .confirmed
        } else {
            phase = tokens == nil ? .unknown : .lastGood
        }
    }

    var text: String {
        guard let tokens else { return "今日尚未确认" }
        return "今日 \(Fmt.tokensShort(tokens))" + (phase == .lastGood ? "（上次成功记录）" : "")
    }

    @MainActor static func current(
        source: HistorySource, state: AppState,
        history: [HistoryStore.DayPoint], todayKey: String
    ) -> SourceTodayConfirmation {
        let saved = history.last { $0.date == todayKey }?.bySource[source]
        func local<T>(_ cache: SourceCache<T>, tokens: Int?) -> SourceTodayConfirmation {
            .init(liveTokens: tokens, recordedTokens: saved,
                presentation: .init(hasResult: cache.result != nil, loading: cache.loading, error: cache.error))
        }
        switch source {
        case .claude: return local(state.claude, tokens: state.claude.result.flatMap {
            $0.isAuthoritative ? $0.dailyTokens(on: todayKey) : nil
        })
        case .codex: return local(state.codex, tokens: state.codex.result.flatMap {
            $0.isAuthoritative ? $0.dailyTokens(on: todayKey) : nil
        })
        case .kimi: return local(state.kimi, tokens: state.kimi.result?.dailyTokens(on: todayKey))
        case .opencode: return local(state.opencode, tokens: state.opencode.result?.dailyTokens(on: todayKey))
        case .gemini: return local(state.gemini, tokens: state.gemini.result?.dailyTokens(on: todayKey))
        case .copilot: return local(state.copilot, tokens: state.copilot.result?.dailyTokens(on: todayKey))
        case .qwen: return local(state.qwen, tokens: state.qwen.result?.dailyTokens(on: todayKey))
        case .cursor: return local(state.cursor, tokens: state.cursor.result?.dailyTokens(on: todayKey))
        case .deepseek:
            let error: String?
            if case .error(let message) = state.usageState { error = message } else { error = nil }
            return .init(liveTokens: state.usage?.days.first { $0.date == todayKey }?.totalTokens,
                recordedTokens: saved, presentation: .init(hasResult: state.usage != nil,
                    loading: state.usageState == .loading, error: error))
        }
    }
}

struct SourceWeekCompareCard: View {
    @Environment(\.usageNow) private var now
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    let source: HistorySource
    @State private var period: PeriodCompare.Period = .week

    private var history: [HistoryStore.DayPoint] { historyReader.dashboardHistory(state: state, todayKey: DateUtil.key(now)).daily }

    var body: some View {
        let history = self.history
        let used = history.contains { ($0.bySource[source] ?? 0) > 0 }
        return Group {
            if used {
                content(history)
            }
        }
    }

    private func content(_ history: [HistoryStore.DayPoint]) -> some View {
        let compare = PeriodCompare.bySource(history, period: period, participants: [source], today: now)
        let this = compare.this[source] ?? 0
        let last = compare.last[source] ?? 0
        let rolling = PeriodCompare.bySource(history, period: .rolling7, participants: [source], today: now)
        let rollingTotal = rolling.this[source] ?? 0
        let average = rollingTotal / 7
        let today = SourceTodayConfirmation.current(source: source, state: state, history: history, todayKey: DateUtil.key(now))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("独立周期对比 · \(period.title)", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("周期", selection: $period) {
                        Text("周").tag(PeriodCompare.Period.week)
                        Text("近7天").tag(PeriodCompare.Period.rolling7)
                        Text("月").tag(PeriodCompare.Period.month)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 104)
                }
                if this > 0 || last > 0 {
                    HStack(spacing: 6) {
                        Text(Fmt.tokensShort(this))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("上期 \(Fmt.tokensShort(last))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        ChangeBadge(change: today.canCompare ? PeriodCompare.change(this: this, last: last) : nil)
                    }
                } else {
                    // 有历史但所选两期皆零(如 codex 只在更早的月份用过):提示而非
                    // 摆一行 "0 上期 0",切档后数字自然回来
                    Text("本周期与上一周期无该来源用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if average > 0 {
                    HStack(spacing: 5) {
                        Text(today.text)
                        Text("· 近 7 天日均 \(Fmt.tokensShort(average))")
                        Spacer()
                        ChangeBadge(change: today.canCompare
                            ? today.tokens.flatMap { PeriodCompare.change(this: $0, last: average) } : nil)
                    }
                    .font(Theme.detailFont)
                    .foregroundStyle(.secondary)
                }
                if !today.canCompare {
                    Text("今日尚未完成成功读取；本期仅展示已有记录，涨跌暂不计算。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
                Text("\(period.footnote)；数据来自本机按天历史。")
                    .font(Theme.footnoteFont).foregroundStyle(.secondary)
            }
        }
    }
}

// 单系列历史柱图。明确入口范围时精确保留 1D/7D/30D/全部；Cursor
// 只有按日合计，不能将它拆成并不存在的逐小时数据。
struct SourceHistoryTrendCard: View {
    struct Bucket: Equatable {
        let date: String
        let label: String
        let value: Int
    }
    @Environment(\.usageNow) private var now
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    let source: HistorySource
    let color: Color
    // 渲染 fixture 注入的按日合计(离屏渲染不读真实 HistoryStore)
    var injectedTotals: [(date: String, tokens: Int)]? = nil
    var previewExportStatus: String? = nil
    @State private var hoverDate: String?
    // 未提供入口范围的旧页面/夹具仍保留 7|30 档。
    @State private var range: UsageHistoryRange
    private let followsEntryRange: Bool
    // 导出完成后的行内反馈(「已导出 <文件名> · 时刻」)
    @State private var exportStatus: String?

    init(
        source: HistorySource, color: Color,
        injectedTotals: [(date: String, tokens: Int)]? = nil,
        previewExportStatus: String? = nil,
        initialRange: UsageHistoryRange? = nil
    ) {
        self.source = source
        self.color = color
        self.injectedTotals = injectedTotals
        self.previewExportStatus = previewExportStatus
        followsEntryRange = initialRange != nil
        _range = State(initialValue: initialRange ?? .week)
    }

    private var history: [HistoryStore.DayPoint] { historyReader.dashboardHistory(state: state, todayKey: DateUtil.key(now)).daily }

    var body: some View {
        // fixture 注入时以注入数据判断可见性(离屏渲染不读真实 HistoryStore)
        let todayKey = DateUtil.key(now)
        let used = totals.contains { key, value in
            key <= todayKey && ModelUsageHistoryStore.isDateKey(key) && value > 0
        }
        return Group {
            if used {
                content
            }
        }
    }

    /// 按日合计；显式零可以覆盖同日旧值，零天由窗口骨架呈现。
    private var totals: [String: Int] {
        if let injectedTotals {
            var map: [String: Int] = [:]
            for entry in injectedTotals {
                map[entry.date] = max(entry.tokens, 0)
            }
            return map
        }
        var map: [String: Int] = [:]
        for day in history {
            guard let value = day.bySource[source] else { continue }
            map[day.date] = max(value, 0)
        }
        return map
    }

    /// 所选档窗口骨架(含零天),保证柱数与日期稳定
    private var buckets: [Bucket] {
        Self.makeBuckets(totals: totals, range: range, todayKey: DateUtil.key(now))
    }

    private var content: some View {
        let buckets = buckets
        let labels = Dictionary(uniqueKeysWithValues: buckets.map { ($0.date, $0.label) })
        let active = buckets.first { $0.date == hoverDate } ?? buckets.last
        let today = SourceTodayConfirmation.current(source: source, state: state, history: history, todayKey: DateUtil.key(now))
        let unknownToday = injectedTotals == nil && range == .day && today.tokens == nil
        let granularity = Self.granularity(totals: totals, range: range, todayKey: DateUtil.key(now))
        return Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("\(range.scopeTitle) Token · \(granularity.rawValue)", systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if !followsEntryRange {
                        Picker("范围", selection: $range) {
                            Text("7天").tag(UsageHistoryRange.week)
                            Text("30天").tag(UsageHistoryRange.month)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 104)
                    }
                    // 导出当前档按日合计 CSV(单系列、附口径行);与来源页
                    // 分量趋势卡同款按钮与文件名规格
                    DashboardExportButton(
                        help: "导出当前档 CSV（按图表粒度分桶，附口径行）",
                        disabled: unknownToday || buckets.isEmpty || !historyReader.canUseSnapshot
                    ) {
                        exportCSV(buckets)
                    }
                    .accessibilityLabel("导出趋势 CSV")
                }
                if unknownToday {
                    ChartHover.emptyState(message: "今日用量尚未确认", hint: "请返回来源页刷新，不将缺记录当作零")
                } else {
                    if let active {
                        ChartHoverCaption(label: granularity == .month ? Fmt.ym(active.date) : Fmt.ymd(active.date),
                            total: active.value, parts: [])
                    }
                    Chart {
                        ForEach(buckets, id: \.date) { bucket in
                            BarMark(x: .value("日期", bucket.date), y: .value("Token", bucket.value))
                                .cornerRadius(1.5)
                                .foregroundStyle(bucket.value > 0 ? color : color.opacity(0.3))
                        }
                        HoverDateRule(date: hoverDate)
                    }
                    .chartXSelection(value: $hoverDate)
                    .dateXAxis(labels: labels)
                    .tokenYAxis()
                    .frame(height: 100)
                }
                if range == .day {
                    Text("该来源仅有按日合计，1D 不推算不存在的逐小时明细。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    if today.phase == .lastGood && injectedTotals == nil {
                        Text("当前展示上次成功记录；本次读取尚未确认，不能据此判断今日涨跌。")
                            .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    }
                }
                if granularity == .week || granularity == .month {
                    Text(granularity == .week ? "按自然周聚合，周一为界；首尾周可能不足整周。"
                         : "按自然月聚合；首尾月可能不足整月。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
                // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
        .onChange(of: range) { _, _ in hoverDate = nil; exportStatus = nil }
    }

    private func exportCSV(_ days: [Bucket]) {
        guard historyReader.canUseSnapshot else {
            exportStatus = historyReader.unavailableMessage
            return
        }
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出趋势 CSV",
            filename: SourceTrendCSVExport.suggestedFilename(
                source: source, spanDays: range.rawValue, todayKey: DateUtil.key(now), scopeTitle: range.scopeTitle)
        ) {
            SourceTrendCSVExport.makeSingleSeriesCSV(
                source: source,
                spanDays: range.rawValue,
                days: days.map { (date: $0.date, tokens: $0.value) }, todayKey: DateUtil.key(now),
                scopeTitle: range.scopeTitle,
                granularity: Self.granularity(totals: totals, range: range, todayKey: DateUtil.key(now))
            )
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }

    static func granularity(
        totals: [String: Int], range: UsageHistoryRange,
        todayKey: String, calendar: Calendar = .current
    ) -> UsageTrendGranularity {
        // HistoryStore retains daily sums only; 1D must not become fake hours.
        guard range == .all else { return .day }
        return range.trendGranularity(historyDayCount:
            dailyBuckets(totals: totals, range: range, todayKey: todayKey, calendar: calendar).count)
    }

    static func makeBuckets(
        totals: [String: Int], range: UsageHistoryRange,
        todayKey: String, calendar: Calendar = .current
    ) -> [Bucket] {
        let days = dailyBuckets(totals: totals, range: range, todayKey: todayKey, calendar: calendar)
        let granularity = range == .all
            ? range.trendGranularity(historyDayCount: days.count) : .day
        guard granularity == .week || granularity == .month else { return days }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        var byKey: [String: Int] = [:]
        for day in days {
            guard let date = DateUtil.date(from: day.date) else { continue }
            let start = granularity == .week
                ? iso.dateInterval(of: .weekOfYear, for: date)?.start
                : calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            guard let start else { continue }
            byKey[DateUtil.key(start), default: 0] += day.value
        }
        return byKey.keys.sorted().map { key in
            Bucket(date: key, label: granularity == .month ? Fmt.ym(key) : "\(Fmt.mmdd(key))周",
                value: byKey[key] ?? 0)
        }
    }

    private static func dailyBuckets(
        totals: [String: Int], range: UsageHistoryRange,
        todayKey: String, calendar: Calendar
    ) -> [Bucket] {
        guard ModelUsageHistoryStore.isDateKey(todayKey), let today = DateUtil.date(from: todayKey)
        else { return [] }
        let values = totals.filter {
            $0.key <= todayKey && ModelUsageHistoryStore.isDateKey($0.key) && $0.value > 0
        }
        let count: Int
        if let fixed = range.fixedDayCount {
            count = fixed
        } else {
            guard let first = values.keys.min(), let start = DateUtil.date(from: first) else { return [] }
            count = (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: today)).day ?? 0) + 1
        }
        guard count > 0 else { return [] }
        return stride(from: count - 1, through: 0, by: -1).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: today))
            else { return nil }
            let key = DateUtil.key(date)
            return Bucket(date: key, label: Fmt.mmdd(key), value: values[key] ?? 0)
        }
    }
}
