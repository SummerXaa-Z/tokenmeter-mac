import SwiftUI
import Charts
import AppKit

struct OverviewTrendCard: View {
    let snapshot: OverviewSnapshot
    let range: UsageHistoryRange
    @State private var hoverHour: Int?
    @State private var hoverLabel: String?
    // 图例 chips 点选隐藏的来源(图表名口径);chips 恒从全量趋势计算,可随时恢复
    @State private var hiddenSources: Set<String> = []
    // 悬停中的图例 chip:说明行临时切到该来源的范围内合计(离屏渲染夹具
    // 用 previewHoverSeries 预置同款状态,指针行为无法离屏模拟)
    @State private var hoverSeries: String?
    // 导出完成后的行内反馈;渲染夹具注入固定文案(保存面板无法离屏模拟)
    @State private var exportStatus: String?
    private let previewExportStatus: String?

    init(
        snapshot: OverviewSnapshot,
        range: UsageHistoryRange,
        previewHoverSeries: String? = nil,
        previewExportStatus: String? = nil
    ) {
        self.snapshot = snapshot
        self.range = range
        _hoverSeries = State(initialValue: previewHoverSeries)
        _exportStatus = State(initialValue: previewExportStatus)
        self.previewExportStatus = previewExportStatus
    }

    private var visibleTrend: [OverviewSnapshot.TrendPoint] {
        TrendSeriesFilter.visible(snapshot.trend, hidden: hiddenSources)
    }

    // 两个粒度分支共用的来源配色，避免两份字典各自漂移
    private static let sourceScale: KeyValuePairs<String, Color> = [
        "Claude": Theme.claude,
        "Codex": Theme.codex, "Kimi Code": Theme.kimi,
        "OpenCode": Theme.opencode,
        "Gemini": Theme.gemini, "Copilot": Theme.copilot,
        "Cursor": Theme.cursor,
    ]

    var body: some View {
        OverviewSection {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        "\(range.scopeTitle) Token 趋势 · \(snapshot.trendGranularity.rawValue)",
                        systemImage: "chart.bar.xaxis"
                    )
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(trendSummary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    // 导出当前范围趋势为 CSV(逐桶一行,来源分列;图例点暗
                    // 隐藏的来源不导,与所见一致)
                    Button {
                        exportCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTrendEmpty)
                    .help("导出当前范围趋势 CSV（逐桶一行、来源分列、附口径行）")
                    .accessibilityLabel("导出趋势 CSV")
                }
                if isTrendEmpty {
                    ChartHover.emptyState(message: emptyMessage, hint: emptyHint)
                } else if snapshot.trendGranularity == .hour {
                    hourlyCaption
                    Chart {
                        ForEach(visibleTrend) { point in
                            if let hour = point.hour {
                                BarMark(
                                    x: .value("小时", hour),
                                    y: .value("Token", point.tokens)
                                )
                                .foregroundStyle(by: .value("源", point.source.overviewChartName))
                                .cornerRadius(1)
                            }
                        }
                        HoverHourRule(hour: hoverHour)
                    }
                    .chartXSelection(value: $hoverHour)
                    .chartForegroundStyleScale(Self.sourceScale)
                    .chartLegend(.hidden)
                    .chartXScale(domain: 0...23)
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                            AxisGridLine(); AxisTick()
                            AxisValueLabel {
                                if let hour = value.as(Int.self) { Text("\(hour)时") }
                            }
                        }
                    }
                    .tokenYAxis()
                    .frame(height: 160)
                } else {
                    bucketCaption
                    Chart {
                        ForEach(visibleTrend) { point in
                            BarMark(
                                x: .value("日期", point.label),
                                y: .value("Token", point.tokens)
                            )
                            .foregroundStyle(by: .value("源", point.source.overviewChartName))
                            .cornerRadius(1)
                        }
                        HoverDateRule(date: hoverLabel)
                    }
                    .chartXSelection(value: $hoverLabel)
                    .chartForegroundStyleScale(Self.sourceScale)
                    // 自定义 seriesChips 已承担图例职责(可点选+悬停读数),
                    // 内置图例与 chips 全量重复,隐藏防叠两套
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisGridLine(); AxisTick(); AxisValueLabel()
                        }
                    }
                    .tokenYAxis()
                    .frame(height: 160)
                }
                seriesChips
                if snapshot.trendGranularity == .hour,
                   !snapshot.hourlyUnattributedSources.isEmpty {
                    Text("\(snapshot.hourlyUnattributedSources.map(\.overviewName).joined(separator: "、")) 仅有今日汇总或小时明细未完整加载，未在小时图中平均摊分。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    /// 导出当前范围趋势 CSV：逐桶一行（小时/日/周/月随所选范围自动降采样），
    /// 来源分列、列序与图例一致；图例点暗的来源不导（与所见一致）。
    /// 保存面板流程与热力图/榜单导出同款，写盘失败弹系统错误框。
    private func exportCSV() {
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出趋势 CSV",
            filename: OverviewTrendCSVExport.suggestedFilename(range: range)
        ) {
            OverviewTrendCSVExport.makeCSV(
                trend: visibleTrend,
                granularity: snapshot.trendGranularity,
                rangeTitle: range.scopeTitle,
                apiValueByTrendBucket: snapshot.apiValueByTrendBucket
            )
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }

    private var trendSummary: String {
        if snapshot.trendGranularity == .hour {
            return "已归因 \(Fmt.tokensShort(snapshot.trendTotal)) / 今日 \(Fmt.tokensShort(snapshot.periodTotal))"
        }
        return "合计 \(Fmt.tokensShort(snapshot.trendTotal))"
    }

    // 空态判定:无桶或整窗全零(全量口径,图例点暗不算空),纯函数可测
    private var isTrendEmpty: Bool {
        TrendSeriesFilter.isAllZero(snapshot.trend)
    }

    // 空态文案拆两行:消息保留口径语义,引导行说明数据怎么来
    private var emptyMessage: String {
        if snapshot.trendGranularity == .hour, snapshot.periodTotal > 0 {
            return "今日已有日汇总，但当前来源没有可验证的小时明细"
        }
        if snapshot.trendGranularity == .hour { return "今日暂无小时用量" }
        return "暂无历史数据"
    }

    private var emptyHint: String? {
        if snapshot.trendGranularity == .hour, snapshot.periodTotal > 0 {
            return nil
        }
        return snapshot.trendGranularity == .hour
            ? "产生用量后这里按小时累积" : "每次刷新后逐日累积"
    }

    // 小时粒度：全部点共享今日一个桶键，直接按钟点分桶；
    // 默认落到最后一个有量的钟点（趋势点覆盖全天 24 个钟点）
    @ViewBuilder private var hourlyCaption: some View {
        let hourly = visibleTrend.filter { $0.hour != nil }
        if hoverHour == nil, let series = hoverSeriesCaption {
            series
        } else if let activeHour = hoverHour
            ?? hourly.last(where: { $0.tokens > 0 })?.hour
            ?? hourly.last?.hour {
            let bucket = hourly.filter { $0.hour == activeHour }
            ChartHoverCaption(
                label: "\(activeHour)时",
                total: bucket.reduce(0) { $0 + $1.tokens },
                parts: bucket.map { ($0.source.overviewChartName, $0.tokens, sourceColor($0.source)) },
                amountText: todayAmountText
            )
        }
    }

    // 日/周/月粒度：按 date 桶键聚合（label 跨年可能重名，不能当桶键）
    @ViewBuilder private var bucketCaption: some View {
        if hoverLabel == nil, let series = hoverSeriesCaption {
            series
        } else if let active = visibleTrend.first(where: { $0.label == hoverLabel })
            ?? visibleTrend.last {
            let bucket = visibleTrend.filter { $0.date == active.date }
            ChartHoverCaption(
                label: active.label,
                total: bucket.reduce(0) { $0 + $1.tokens },
                parts: bucket.map { ($0.source.overviewChartName, $0.tokens, sourceColor($0.source)) },
                amountText: bucketAmountText(active.date)
            )
        }
    }

    // 小时粒度的金额：按天明细只有日粒度，悬停任何钟点都显示今日合计
    private var todayAmountText: String? {
        guard let today = visibleTrend.first?.date,
              let bySource = snapshot.apiValueByTrendBucket[today],
              !bySource.isEmpty else { return nil }
        return amountText(summing: bySource)
    }

    private func bucketAmountText(_ bucketKey: String) -> String? {
        guard let bySource = snapshot.apiValueByTrendBucket[bucketKey],
              !bySource.isEmpty else { return nil }
        return amountText(summing: bySource)
    }

    // 图例隐藏的来源不计入金额，与说明行的 token 合计同口径
    private func amountText(
        summing bySource: [HistorySource: Double]
    ) -> String? {
        let visible = bySource
            .filter { !hiddenSources.contains($0.key.overviewChartName) }
            .reduce(0.0) { $0 + $1.value }
        guard visible > 0 else { return nil }
        return Fmt.usd(visible)
    }

    // 图例 chip 悬停:说明行临时切到该来源的范围内合计,多来源横比不用
    // 来回点开图例;金额为该来源范围内 API 等价(悬停金额同口径,不随
    // 图例隐藏——被隐藏的来源也照样读数)
    private var hoverSeriesCaption: ChartHoverCaption? {
        guard let name = hoverSeries,
              let summary = OverviewSeriesHover.summary(
                name: name,
                seriesTotals: TrendSeriesFilter.seriesTotals(snapshot.trend),
                rangeTotal: snapshot.trendTotal,
                amount: seriesAmount(name)) else { return nil }
        return ChartHoverCaption(
            label: summary.label, total: summary.total, parts: [],
            amountText: summary.amountText)
    }

    private func seriesAmount(_ chartName: String) -> Double? {
        let total = snapshot.apiValueByTrendBucket.values.reduce(0.0) { sum, bySource in
            sum + bySource
                .filter { $0.key.overviewChartName == chartName }
                .reduce(0.0) { $0 + $1.value }
        }
        return total > 0 ? total : nil
    }

    private func sourceColor(_ source: HistorySource) -> Color {
        color(forChartName: source.overviewChartName)
    }

    private func color(forChartName name: String) -> Color {
        Self.sourceScale.first { $0.key == name }?.value ?? Theme.brand
    }

    // 来源点选 chips：替代内置图例,点暗即从图中隐藏该系列;悬停时说明行
    // 临时显示该来源的范围内合计(含被隐藏的来源),help 同步给出口径
    @ViewBuilder private var seriesChips: some View {
        let series = TrendSeriesFilter.seriesTotals(snapshot.trend)
        if !series.isEmpty {
            HStack(spacing: 4) {
                ForEach(series, id: \.name) { entry in
                    seriesChip(entry)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func seriesChip(_ entry: (name: String, total: Int)) -> some View {
        let name = entry.name
        let isOn = !hiddenSources.contains(name)
        return Button {
            if isOn {
                hiddenSources.insert(name)
            } else {
                hiddenSources.remove(name)
            }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(color(forChartName: name))
                    .frame(width: 5, height: 5)
                    .opacity(isOn ? 1 : 0.25)
                Text(name)
                    .font(Theme.detailFont)
                    .foregroundStyle(.primary)
                    .opacity(isOn ? 1 : 0.4)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .onHover { hovering in
            if hovering {
                hoverSeries = name
            } else if hoverSeries == name {
                hoverSeries = nil
            }
        }
        .help("范围内合计 \(Fmt.tokensShort(entry.total)) · " +
              (isOn ? "点按隐藏" : "点按显示"))
        .accessibilityLabel(isOn ? "隐藏 \(name) 系列" : "显示 \(name) 系列")
    }
}

extension HistorySource {
    var overviewName: String { LocalUsageCollectorRegistry.displayName(for: self) }

    var overviewChartName: String {
        switch self {
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .qwen: return "Qwen"
        default: return overviewName
        }
    }

    var overviewColor: Color {
        switch self {
        case .deepseek: return Theme.brand
        case .claude: return Theme.claude
        case .codex: return Theme.codex
        case .kimi: return Theme.kimi
        case .opencode: return Theme.opencode
        case .gemini: return Theme.gemini
        case .copilot: return Theme.copilot
        case .qwen: return Theme.qwen
        case .cursor: return Theme.cursor
        }
    }
}
