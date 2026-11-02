import SwiftUI
import Charts
import AppKit

// Coding 模型下钻页：保留总览入口范围，并允许切换 1D/7D/30D/90D/全部。
// 范围控件在空态也可用；Token 构成、金额、导出全部同窗。
struct CodingModelDetailView: View {
    enum Span: Int, CaseIterable {
        case day = 1
        case week = 7
        case month = 30
        case quarter = 90
        case all = 0

        var title: String { self == .all ? "全部" : "\(rawValue)D" }
        var scopeTitle: String {
            self == .all ? "全部本机历史" : self == .day ? "今日" : "近 \(rawValue) 天"
        }
        init(range: UsageHistoryRange) {
            switch range {
            case .day: self = .day
            case .week: self = .week
            case .month: self = .month
            case .all: self = .all
            }
        }
    }

    let source: HistorySource
    let model: String
    let onBack: () -> Void
    // 渲染/测试注入固定快照（入参为窗口天数）；nil 时按实时采集 + 本机
    // 留存自算（与模型榜同源）
    var injectedFor: ((Int) -> CodingModelDetail.Summary?)? = nil
    @EnvironmentObject var state: AppState
    @Environment(\.usageNow) private var now
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    @State private var span: Span
    @State private var hoverDate: String?
    // 导出完成后的行内反馈;渲染夹具注入固定文案(离屏渲染无法模拟
    // 保存面板)
    @State private var exportStatus: String?
    private let previewExportStatus: String?

    init(
        source: HistorySource,
        model: String,
        onBack: @escaping () -> Void,
        injectedFor: ((Int) -> CodingModelDetail.Summary?)? = nil,
        initialSpan: Span = .month,
        initialRange: UsageHistoryRange? = nil,
        previewExportStatus: String? = nil
    ) {
        self.source = source
        self.model = model
        self.onBack = onBack
        self.injectedFor = injectedFor
        _span = State(initialValue: initialRange.map { Span(range: $0) } ?? initialSpan)
        _exportStatus = State(initialValue: previewExportStatus)
        self.previewExportStatus = previewExportStatus
    }

    private func summary(for span: Span) -> CodingModelDetail.Summary? {
        if let injectedFor {
            return injectedFor(span.rawValue)
        }
        return CodingModelDetail.summary(
            source: source, model: model,
            liveDayModels: Self.liveDayModels(source, state: state),
            persisted: historyReader.dashboardHistory(state: state, todayKey: DateUtil.key(now)).models,
            todayKey: DateUtil.key(now), windowDays: max(span.rawValue, 1), allHistory: span == .all)
    }

    var body: some View {
        let s = summary(for: span)
        return ScrollView {
            VStack(spacing: 12) {
                header
                statsCard(s)
                if let s {
                    breakdownCard(s)
                    trendCard(s)
                } else {
                    ChartHover.emptyState(
                        message: "\(span.scopeTitle)暂无该模型明细",
                        hint: span == .all ? "尚无本机留存；返回总览刷新来源数据" : "可切换上方范围查看更早记录")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .onChange(of: span) { _, _ in hoverDate = nil; exportStatus = nil }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "brain",
            title: model,
            color: source.overviewColor,
            onBack: onBack)
    }

    private func statsCard(_ s: CodingModelDetail.Summary?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("模型用量", systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("范围", selection: $span) {
                        ForEach(Span.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 230)
                    .accessibilityIdentifier("TokenMeter.Model.Range")
                }
                HStack(spacing: 16) {
                    stat("\(span.scopeTitle) Token", s.map { Fmt.tokensShort($0.tally.total) } ?? "—")
                    stat("活跃天数", s.map { "\($0.activeDays)" } ?? "—")
                    stat("API 等价", s.map { summary in
                        guard let amount = summary.pricedTotalUSD else { return "未知" }
                        return (summary.coverage.map { $0 < 0.999 } == true ? "至少 " : "") + Fmt.usd(amount)
                    } ?? "无明细")
                }
                Text(source.overviewName + " · " + span.scopeTitle)
                    .font(Theme.footnoteFont).foregroundStyle(.secondary)
                if let price = ModelPriceCheatSheet.caption(model: model, on: DateUtil.key(now)) {
                    Text("当前生效参考单价（输入 / 输出，每百万 tokens）：\(price)")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                } else {
                    Text("当前目录没有该模型的生效参考价；历史金额仍按用量当日价格判断。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func breakdownCard(_ s: CodingModelDetail.Summary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Token 构成（\(span.scopeTitle)）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                let parts = SourceTrendCard.parts(source, of: s.tally).filter { $0.value > 0 }
                if parts.isEmpty {
                    Text("暂无用量")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        HStack {
                            Circle().fill(part.color).frame(width: 8, height: 8)
                            Text(part.name).font(.system(size: 12))
                            Spacer()
                            Text(Fmt.int(part.value))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func trendCard(_ s: CodingModelDetail.Summary) -> some View {
        let granularity = Self.granularity(span: span, days: s.days.count)
        let points = CodingModelDetail.trendValues(from: s.days, granularity: granularity)
        let labels = Dictionary(uniqueKeysWithValues: points.map { ($0.key, $0.label) })
        let active = points.first { $0.key == hoverDate } ?? points.last(where: { $0.tokens > 0 }) ?? points.last
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(span.scopeTitle) API 等价 · \(granularity.rawValue)", systemImage: "dollarsign.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    DashboardExportButton(
                        help: "导出当前档 CSV（Token 与 API 等价，附口径行）",
                        disabled: !historyReader.canUseSnapshot
                    ) {
                        exportCSV(s)
                    }
                    .accessibilityLabel("导出模型明细 CSV")
                }
                if let active {
                    ChartHoverCaption(
                        label: Self.bucketCaption(active.key, granularity: granularity),
                        total: active.tokens,
                        parts: SourceTrendCard.parts(source, of: active.tally).filter { $0.value > 0 },
                        amountText: Self.amountCaption(active))
                }
                Chart {
                    ForEach(points, id: \.key) { point in
                        if let amount = point.pricedUSD {
                            BarMark(x: .value("日期", point.key), y: .value("金额", amount))
                                .foregroundStyle(source.overviewColor.opacity(0.85))
                                .cornerRadius(2)
                        } else {
                            // A missing price is an unpriced gap, not a zero-cost bar.
                            RuleMark(x: .value("未计价日期", point.key))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }
                    HoverDateRule(date: hoverDate)
                }
                .chartXSelection(value: $hoverDate)
                .numericYAxis()
                .dateXAxis(labels: labels)
                .frame(height: 140)
                if span == .day {
                    Text("模型明细仅按天留存；1D 展示今日合计，不推算逐小时费用。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                } else if granularity == .week || granularity == .month {
                    Text(granularity == .week
                         ? "按自然周聚合（周一为界，首尾周可能不足整周），柱形与查值均为周合计。"
                         : "按自然月聚合（首尾月可能不足整月），柱形与查值均为月合计。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
                if let coverage = s.coverage, coverage < 0.999 {
                    Text("价格覆盖 \(Int((coverage * 100).rounded()))%；虚线为未计价桶，不代表零费用。部分计价桶的金额为下限。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
                Text("按用量当日生效的价格快照重算（最近核对 \(APIReferencePricingCatalog.observedAt)）。仅表示该模型的 API 等价成本，不是订阅费或平台账单；运行时不联网。")
                    .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func granularity(span: Span, days: Int) -> UsageTrendGranularity {
        if span == .quarter { return .week }
        if span == .all { return UsageHistoryRange.all.trendGranularity(historyDayCount: days) }
        return .day
    }

    static func amountCaption(_ point: CodingModelDetail.TrendValue) -> String {
        guard let amount = point.pricedUSD else { return "API 等价未知（缺价）" }
        if point.tokens == 0 { return "API 等价 \(Fmt.usd(0)) · 无 Token" }
        if point.isPartial { return "API 等价至少 \(Fmt.usd(amount))" }
        return "API 等价 \(Fmt.usd(amount))" + (amount == 0 ? "（已知零价）" : "")
    }

    private static func bucketCaption(_ key: String, granularity: UsageTrendGranularity) -> String {
        if granularity == .month { return Fmt.ym(key) }
        return Fmt.ymd(key) + (granularity == .week ? "周" : "")
    }

    /// 导出当前档明细 CSV；保存面板流程与模型榜/Skill 详情导出同款，
    /// 写盘失败弹系统错误框。90 天档按周聚合、短档逐日，与趋势图同桶。
    private func exportCSV(_ s: CodingModelDetail.Summary) {
        guard historyReader.canUseSnapshot else {
            exportStatus = historyReader.unavailableMessage
            return
        }
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出模型明细 CSV",
            filename: CodingModelDetailCSVExport.suggestedFilename(model: model)
        ) {
            let granularity = Self.granularity(span: span, days: s.days.count)
            let rows = CodingModelDetail.trendValues(from: s.days, granularity: granularity).map {
                CodingModelDetailCSVExport.Row(bucket: $0.key, tokens: $0.tokens, usd: $0.pricedUSD)
            }
            return CodingModelDetailCSVExport.makeCSV(
                source: source, model: model, spanDays: span.rawValue,
                rows: rows, coverage: s.coverage, todayKey: DateUtil.key(now),
                scopeTitle: span.scopeTitle, granularity: granularity
            )
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }

    /// 各来源实时采集的逐日模型明细；平台账户与 Cursor 榜单天然不进此页。
    static func liveDayModels(
        _ source: HistorySource, state: AppState
    ) -> [String: [String: ModelTokenTally]]? {
        switch source {
        case .claude: return state.claude.result?.dayModels
        case .codex: return state.codex.result?.dayModels
        case .kimi: return state.kimi.result?.dayModels
        case .opencode: return state.opencode.result?.dayModels
        case .gemini: return state.gemini.result?.dayModels
        case .copilot: return state.copilot.result?.dayModels
        case .qwen: return state.qwen.result?.dayModels
        case .cursor, .deepseek: return nil
        }
    }
}
