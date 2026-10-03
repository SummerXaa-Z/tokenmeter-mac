import SwiftUI
import Charts
import AppKit

// 来源页通用的历史分析卡。自包含读取本机按天历史(HistoryStore),不依赖
// 各来源的实时采集——工具未运行、本地数据暂时缺失时历史对比依然可见,
// 与"数据路径消失不抹掉已积累历史"的既有承诺一致。从未有过记录时整卡隐藏。

// 单来源周期环比:周|近7天|月 三档(与总览环比卡同口径),下挂一行
// 今日 vs 近 7 天日均的滚动参照。Claude 页保留更细的缓存拆解周趋势,不用此卡。
// 历史在 body 内直接读取:按天历史 JSON 极小(毫秒级),不依赖 .task 的
// appear 时序——挂在初始为空的视图上时,离屏渲染等场景可能永不触发。
struct SourceWeekCompareCard: View {
    let source: HistorySource
    @State private var period: PeriodCompare.Period = .week

    private var history: [HistoryStore.DayPoint] { HistoryStore.all() }

    var body: some View {
        let used = history.contains { ($0.bySource[source] ?? 0) > 0 }
        return Group {
            if used {
                content
            }
        }
    }

    private var content: some View {
        let compare = PeriodCompare.bySource(history, period: period, participants: [source])
        let this = compare.this[source] ?? 0
        let last = compare.last[source] ?? 0
        let rolling = PeriodCompare.bySource(history, period: .rolling7, participants: [source])
        let rollingTotal = rolling.this[source] ?? 0
        let average = rollingTotal / 7
        let today = history.first { $0.date == DateUtil.today() }?.bySource[source] ?? 0
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(period.title)", systemImage: "arrow.up.arrow.down")
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
                        ChangeBadge(change: PeriodCompare.change(this: this, last: last))
                    }
                } else {
                    // 有历史但所选两期皆零(如 codex 只在更早的月份用过):提示而非
                    // 摆一行 "0 上期 0",切档后数字自然回来
                    Text("本周期与上一周期无该来源用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if average > 0 {
                    HStack(spacing: 5) {
                        Text("今日 \(Fmt.tokensShort(today))")
                        Text("· 近 7 天日均 \(Fmt.tokensShort(average))")
                        Spacer()
                        ChangeBadge(change: PeriodCompare.change(this: today, last: average))
                    }
                    .font(Theme.detailFont)
                    .foregroundStyle(.secondary)
                }
                Text("\(period.footnote)；数据来自本机按天历史。")
                    .font(Theme.footnoteFont).foregroundStyle(.tertiary)
            }
        }
    }
}

// 近 7 天单系列历史柱图。其他来源的 7 天图来自各自实时采集,带分量堆叠;
// Cursor 只有订阅周期聚合,趋势走按天历史,故单独成卡(悬停查值同款)。
struct SourceHistoryTrendCard: View {
    let source: HistorySource
    let color: Color
    // 渲染 fixture 注入的按日合计(离屏渲染不读真实 HistoryStore)
    var injectedTotals: [(date: String, tokens: Int)]? = nil
    var previewExportStatus: String? = nil
    @State private var hoverDate: String?
    // 与来源页趋势卡同款 7|30 档(Cursor 只有按日合计,无分量无金额)
    @State private var span: SourceTrendCard.Span = .week
    // 导出完成后的行内反馈(「已导出 <文件名> · 时刻」)
    @State private var exportStatus: String?

    private var history: [HistoryStore.DayPoint] { HistoryStore.all() }

    var body: some View {
        // fixture 注入时以注入数据判断可见性(离屏渲染不读真实 HistoryStore)
        let used = injectedTotals.map { $0.contains { $0.tokens > 0 } }
            ?? history.contains { ($0.bySource[source] ?? 0) > 0 }
        return Group {
            if used {
                content
            }
        }
    }

    /// 有量的日期 → 当日合计(>0 才进表,零天由窗口骨架补)
    private var totals: [String: Int] {
        if let injectedTotals {
            var map: [String: Int] = [:]
            for entry in injectedTotals where entry.tokens > 0 {
                map[entry.date] = entry.tokens
            }
            return map
        }
        var map: [String: Int] = [:]
        for day in history {
            let value = max(day.bySource[source] ?? 0, 0)
            if value > 0 { map[day.date] = value }
        }
        return map
    }

    /// 所选档窗口骨架(含零天),保证柱数与日期稳定
    private var buckets: [(date: String, label: String, value: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [(date: String, label: String, value: Int)] = []
        for offset in stride(from: -(span.rawValue - 1), through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let key = DateUtil.key(date)
            result.append((key, Fmt.mmdd(date), totals[key] ?? 0))
        }
        return result
    }

    private var content: some View {
        let buckets = buckets
        let captions = buckets.map { (label: $0.label, total: $0.value, parts: [(name: String, value: Int, color: Color)]()) }
        return Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("近 \(span.rawValue) 天 Token", systemImage: "chart.bar.fill")
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
                    // 导出当前档按日合计 CSV(单系列、附口径行);与来源页
                    // 分量趋势卡同款按钮与文件名规格
                    Button {
                        exportCSV(buckets)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(buckets.allSatisfy { $0.value == 0 })
                    .help("导出当前档 CSV（逐日一行按日合计，附口径行）")
                    .accessibilityLabel("导出趋势 CSV")
                }
                ChartHover.caption(hover: hoverDate, buckets: captions)
                Chart {
                    ForEach(buckets, id: \.date) { bucket in
                        BarMark(
                            x: .value("日期", bucket.label),
                            y: .value("Token", bucket.value)
                        )
                        .cornerRadius(1.5)
                        .foregroundStyle(bucket.value > 0 ? color : color.opacity(0.3))
                    }
                    HoverDateRule(date: hoverDate)
                }
                .chartXSelection(value: $hoverDate)
                .tokenYAxis()
                .frame(height: 100)
                // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    private func exportCSV(_ days: [(date: String, label: String, value: Int)]) {
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出趋势 CSV",
            filename: SourceTrendCSVExport.suggestedFilename(
                source: source, spanDays: span.rawValue)
        ) {
            SourceTrendCSVExport.makeSingleSeriesCSV(
                source: source,
                spanDays: span.rawValue,
                days: days.map { (date: $0.date, tokens: $0.value) }
            )
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }
}
