import SwiftUI
import Charts

// Coding 模型下钻页：从总览模型榜点入。页面自成「近 30 天」固定口径
// （榜单行的 Token 随总览所选范围变化），Token 构成、逐日 API 等价
// 金额与覆盖率全部同窗，数字之间可直接对照。
struct CodingModelDetailView: View {
    let source: HistorySource
    let model: String
    var onBack: () -> Void
    // 渲染/测试注入固定快照；nil 时按实时采集 + 本机留存自算（与模型榜同源）
    var injected: CodingModelDetail.Summary? = nil
    @EnvironmentObject var state: AppState
    @State private var hoverDate: String?

    private var summary: CodingModelDetail.Summary? {
        injected ?? CodingModelDetail.summary(
            source: source, model: model,
            liveDayModels: Self.liveDayModels(source, state: state))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if let s = summary {
                statsCard(s)
                breakdownCard(s)
                trendCard(s)
            } else {
                SourceStateView(message: "近 30 天暂无该模型明细")
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
                HStack(spacing: 16) {
                    stat("近 30 天 Token", Fmt.tokensShort(s.tally.total))
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
                Text("Token 构成（近 30 天）")
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
        let byLabel = Dictionary(
            uniqueKeysWithValues: s.days.map { (Fmt.mmdd($0.date), $0) })
        let usdFor: (String) -> String? = { label in
            guard let day = byLabel[label], day.usd > 0 else { return nil }
            return Fmt.usd(day.usd)
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("近 30 天 API 等价（USD）", systemImage: "dollarsign.circle")
                    .font(.system(size: 12, weight: .semibold))
                ChartHover.caption(
                    hover: hoverDate,
                    amountFor: usdFor,
                    buckets: s.days.map { day in
                        (
                            label: Fmt.mmdd(day.date),
                            total: day.tokens,
                            parts: SourceTrendCard.parts(source, of: day.tally)
                                .filter { $0.value > 0 }
                        )
                    })
                Chart {
                    ForEach(Array(s.days.enumerated()), id: \.offset) { _, day in
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("金额", day.usd))
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
