import SwiftUI
import Charts
import AppKit

// Coding 模型下钻页：从总览模型榜点入。页面自成固定窗口口径（榜单行的
// Token 随总览所选范围变化），7|30|90 天切换；Token 构成、逐日 API 等价
// 金额与覆盖率全部同窗，数字之间可直接对照。
struct CodingModelDetailView: View {
    enum Span: Int, CaseIterable {
        case week = 7
        case month = 30
        case quarter = 90

        var title: String { "\(rawValue)天" }
    }

    let source: HistorySource
    let model: String
    let onBack: () -> Void
    // 渲染/测试注入固定快照（入参为窗口天数）；nil 时按实时采集 + 本机
    // 留存自算（与模型榜同源）
    var injectedFor: ((Int) -> CodingModelDetail.Summary?)? = nil
    @EnvironmentObject var state: AppState
    @State private var span: Span
    @State private var hoverDate: String?

    init(
        source: HistorySource,
        model: String,
        onBack: @escaping () -> Void,
        injectedFor: ((Int) -> CodingModelDetail.Summary?)? = nil,
        initialSpan: Span = .month
    ) {
        self.source = source
        self.model = model
        self.onBack = onBack
        self.injectedFor = injectedFor
        _span = State(initialValue: initialSpan)
    }

    private func summary(for span: Span) -> CodingModelDetail.Summary? {
        if let injectedFor {
            return injectedFor(span.rawValue)
        }
        return CodingModelDetail.summary(
            source: source, model: model,
            liveDayModels: Self.liveDayModels(source, state: state),
            windowDays: span.rawValue)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if let s = summary(for: span) {
                statsCard(s)
                breakdownCard(s)
                trendCard(s)
            } else {
                SourceStateView(message: "近 \(span.rawValue) 天暂无该模型明细，可切到更长范围")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "brain",
            title: model,
            color: source.overviewColor,
            onBack: onBack)
    }

    private func statsCard(_ s: CodingModelDetail.Summary) -> some View {
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
                    .frame(width: 130)
                }
                HStack(spacing: 16) {
                    stat("近 \(span.rawValue) 天 Token", Fmt.tokensShort(s.tally.total))
                    stat("活跃天数", "\(s.activeDays)")
                    stat("API 等价", Fmt.usd(s.totalUSD))
                }
                if let price = ModelPriceCheatSheet.caption(model: model) {
                    Text("当前生效参考单价（输入 / 输出，每百万 tokens）：\(price)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("当前价格目录未收录该模型，金额栏不计入。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func breakdownCard(_ s: CodingModelDetail.Summary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Token 构成（近 \(span.rawValue) 天）")
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
        // 90 天档按自然周聚合（与总览「全部」的周粒度同口径），短档逐日
        let weekly = span == .quarter
        let points: [(label: String, usd: Double, tally: ModelTokenTally)]
        if weekly {
            points = CodingModelDetail.weeklyBuckets(from: s.days).map {
                (label: "\(Fmt.mmdd($0.weekStart))周", usd: $0.usd, tally: $0.tally)
            }
        } else {
            points = s.days.map {
                (label: Fmt.mmdd($0.date), usd: $0.usd, tally: $0.tally)
            }
        }
        let byLabel = Dictionary(
            uniqueKeysWithValues: points.map { ($0.label, $0) })
        let usdFor: (String) -> String? = { label in
            guard let point = byLabel[label], point.usd > 0 else { return nil }
            return Fmt.usd(point.usd)
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("近 \(span.rawValue) 天 API 等价（USD）", systemImage: "dollarsign.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // 导出当前档走势（7/30 天逐日、90 天按周聚合），与
                    // Skill 详情页导出同款入口
                    Button {
                        exportCSV(s)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("导出当前档 CSV（Token 与 API 等价，附口径行）")
                    .accessibilityLabel("导出模型明细 CSV")
                }
                ChartHover.caption(
                    hover: hoverDate,
                    amountFor: usdFor,
                    buckets: points.map { point in
                        (
                            label: point.label,
                            total: point.tally.total,
                            parts: SourceTrendCard.parts(source, of: point.tally)
                                .filter { $0.value > 0 }
                        )
                    })
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        BarMark(
                            x: .value(weekly ? "周" : "日期", point.label),
                            y: .value("金额", point.usd))
                            .foregroundStyle(source.overviewColor.opacity(0.85))
                            .cornerRadius(2)
                    }
                    HoverDateRule(date: hoverDate)
                }
                .chartXSelection(value: $hoverDate)
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel()
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 140)
                if weekly {
                    Text("该档按自然周聚合（周一为界，首尾周可能不足整周），柱形与悬停均为周合计。")
                        .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                }
                if let coverage = s.coverage, coverage < 0.999 {
                    Text("价格覆盖 \(Int((coverage * 100).rounded()))%，缺价或价格未生效的用量不计入金额。")
                        .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                }
                Text("按用量当日生效的价格快照重算（最近核对 \(APIReferencePricingCatalog.observedAt)）。仅表示该模型的 API 等价成本，不是订阅费或平台账单；运行时不联网。")
                    .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// 导出当前档明细 CSV；保存面板流程与模型榜/Skill 详情导出同款，
    /// 写盘失败弹系统错误框。90 天档按周聚合、短档逐日，与趋势图同桶。
    private func exportCSV(_ s: CodingModelDetail.Summary) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出模型明细 CSV"
        panel.nameFieldStringValue = CodingModelDetailCSVExport.suggestedFilename(model: model)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows: [CodingModelDetailCSVExport.Row]
        if span == .quarter {
            rows = CodingModelDetail.weeklyBuckets(from: s.days).map {
                CodingModelDetailCSVExport.Row(
                    bucket: $0.weekStart, tokens: $0.tokens, usd: $0.usd)
            }
        } else {
            rows = s.days.map {
                CodingModelDetailCSVExport.Row(
                    bucket: $0.date, tokens: $0.tokens, usd: $0.usd)
            }
        }
        do {
            try CodingModelDetailCSVExport.makeCSV(
                source: source, model: model, spanDays: span.rawValue,
                rows: rows, coverage: s.coverage
            ).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出模型明细 CSV 失败"
            alert.runModal()
        }
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
