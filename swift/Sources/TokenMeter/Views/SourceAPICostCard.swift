import SwiftUI

// 来源页通用的「API 等价参考」卡，支持 周|近7天|月 切换（与同页历史环比
// 卡同窗口口径）。价格与总览同口径（按用量当日生效的快照重算），数据来自
// 实时采集的 dayModels + 共享快照的按天明细：不触发磁盘读取、不依赖实时采集
// 成功——工具没跑、本地路径暂时缺失时依然可见，从未有过明细时整卡隐藏
// （同 SourceWeekCompareCard 的承诺）。
struct SourceAPICostCard: View {
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    let source: HistorySource
    let liveDayModels: [String: [String: ModelTokenTally]]?
    // 测试/渲染注入用；nil 时读本机设置（自包含，与 persisted 留存同思路）
    var subscriptionPlans: [SubscriptionPlan]? = nil
    // 同上:注入固定回本走势点;nil 时按归属订阅与本机留存自行计算
    var roiCurve: [SubscriptionROICurve.WeekPoint]? = nil
    @State private var period: PeriodCompare.Period = .week

    var body: some View {
        let used = SourceAPICost.everUsed(source: source, liveDayModels: liveDayModels,
                                          persisted: historyReader.snapshot.models)
        return Group {
            if used {
                content
            }
        }
    }

    private var content: some View {
        let summary = SourceAPICost.summary(
            source: source, liveDayModels: liveDayModels, period: period,
            persisted: historyReader.snapshot.models)
        let prior = SourceAPICost.priorSummary(
            source: source, liveDayModels: liveDayModels, period: period,
            persisted: historyReader.snapshot.models)
        let plans = subscriptionPlans ?? ConfigStore.shared.subscriptionPlans
        let subscription = SourceAPICost.subscriptionValue(
            source: source, liveDayModels: liveDayModels,
            period: period, plans: plans, persisted: historyReader.snapshot.models)
        let curve = roiCurve ?? Self.roiCurve(
            source: source, plans: plans, persisted: historyReader.snapshot.models)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("API 等价参考（\(period.shortTitle)）", systemImage: "dollarsign.circle")
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
                if let summary {
                    detail(summary, prior: prior, subscription: subscription,
                           roiCurve: curve)
                } else if let prior, prior.total > 0 {
                    // 有历史但所选周期暂无明细（如本周还没用过）：带上期金额
                    // 做参照，切档后数字自然回来（与环比卡同语义）
                    Text("本周期暂无该来源用量明细；上期 \(Fmt.usd(prior.total))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("本周期暂无该来源用量明细")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // 该来源的回本走势:分母只算归属到该来源的订阅月费;未归属订阅为空
    static func roiCurve(
        source: HistorySource,
        plans: [SubscriptionPlan],
        persisted: [ModelUsageDay] = [],
        today: Date = Date()
    ) -> [SubscriptionROICurve.WeekPoint] {
        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(plans, tagged: source)
        guard monthlyFee > 0 else { return [] }
        return SubscriptionROICurve.weeklyPoints(
            participants: [source], monthlyFeeUSD: monthlyFee,
            persisted: persisted, today: today)
    }

    private func detail(
        _ summary: APIReferenceCostSummary,
        prior: APIReferenceCostSummary?,
        subscription: SubscriptionValueSummary?,
        roiCurve: [SubscriptionROICurve.WeekPoint]
    ) -> some View {
        let coverage = summary.coverage ?? 0
        let priorText: String = {
            if let prior { return "上期 \(Fmt.usd(prior.total))" }
            return "上期 —"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(summary.amounts.isEmpty ? "暂无参考价" : Fmt.usd(summary.total))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brand)
                Text(priorText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ChangeBadge(change: PeriodCompare.change(
                    this: summary.total, last: prior?.total ?? 0))
            }
            HStack {
                Text("价格覆盖").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((coverage * 100).rounded()))% · \(Fmt.tokensShort(summary.matchedTokens)) tokens")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            QuotaBar(progress: coverage, tint: coverage >= 0.95 ? Theme.hit : .orange)

            ForEach(Array(summary.modelAmounts.prefix(3).enumerated()), id: \.element.id) {
                index, amount in
                amountRow(rank: index + 1, amount: amount, total: summary.total)
            }
            UnpricedModelsNote(names: summary.unpricedModels)
            if let conversion = conversionNote(summary) {
                Text(conversion)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let subscription {
                // 与总览 API 等价卡的订阅回本同款式；只在设置为该来源
                // 填写过订阅时出现，未拆分的来源不打扰
                Divider()
                HStack {
                    Text("订阅回本").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(subscription.multiple.map(SubscriptionValueSummary.multipleText) ?? "—")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                }
                Text(subscription.detailText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !roiCurve.isEmpty {
                    SubscriptionROITrendChart(points: roiCurve)
                }
            }
            Text(policyText(summary))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func amountRow(
        rank: Int, amount: APIReferenceCostSummary.ModelAmount, total: Double
    ) -> some View {
        let share = total > 0 ? amount.total / total : 0
        return HStack(spacing: 7) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
                .frame(width: 14)
            Circle().fill(source.overviewColor).frame(width: 6, height: 6)
            Text(amount.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(Fmt.usd(amount.total)) · \(Int((share * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func conversionNote(_ summary: APIReferenceCostSummary) -> String? {
        guard summary.currency == "USD",
              let cny = summary.amounts.first(where: { $0.currency == "CNY" }),
              let rate = summary.conversionRates["CNY"], rate > 0 else { return nil }
        return String(
            format: "含人民币公开价 ¥%.2f，按固定参考汇率 $1 = ¥%.2f 折算。",
            cny.total, 1 / rate)
    }

    private func policyText(_ summary: APIReferenceCostSummary) -> String {
        let sourceText: String
        if summary.sourceLabels.isEmpty {
            sourceText = "价格规则为 OpenRouter 优先，缺价时采用模型官方公开价"
        } else {
            sourceText = "按用量当日生效的 \(summary.sourceLabels.joined(separator: " + ")) 价格快照重算（最近核对 \(APIReferencePricingCatalog.observedAt)）"
        }
        return "\(period.footnote)；\(sourceText)。仅表示该来源的 API 等价成本，不是订阅费或平台账单；运行时不联网。"
    }
}

// 来源页 7|30 天趋势图共用的悬停金额闭包：mmdd label → 当日 API 等价金额
// 文本。数据走 SourceAPICost.dailyValues（实时 dayModels 覆盖留存同一天），
// windowDays 与图表档位一致（7 天或 30 天）。
enum SourceHoverAmount {
    static func make(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        days: [String],   // 图中各桶的自然日键(YYYY-MM-DD)
        windowDays: Int = 7,
        persisted: [ModelUsageDay] = []
    ) -> (String) -> String? {
        let values = SourceAPICost.dailyValues(
            source: source, liveDayModels: liveDayModels, persisted: persisted, windowDays: windowDays)
        let labels = Dictionary(uniqueKeysWithValues: days.map { (Fmt.mmdd($0), $0) })
        return { label in
            guard let key = labels[label], let value = values[key], value > 0 else { return nil }
            return Fmt.usd(value)
        }
    }
}
