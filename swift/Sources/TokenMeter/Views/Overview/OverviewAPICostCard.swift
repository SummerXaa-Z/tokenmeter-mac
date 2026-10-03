import SwiftUI

struct OverviewAPICostCard: View {
    let summary: APIReferenceCostSummary
    let range: UsageHistoryRange
    // 固定范围的上期基期金额(环比徽标);「全部」为 nil
    var priorSummary: APIReferenceCostSummary? = nil
    var subscriptionValue: SubscriptionValueSummary? = nil
    // 回本走势:近 13 个完整周逐周倍数;空则不画
    var roiCurve: [SubscriptionROICurve.WeekPoint] = []
    var coverageNote: String? = nil

    var body: some View {
        let coverage = summary.coverage ?? 0
        OverviewSection {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(range.scopeTitle) API 等价参考", systemImage: "dollarsign.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if range.fixedDayCount != nil {
                        Text("上期对比")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(summary.amounts.isEmpty ? "暂无参考价" : Fmt.usd(summary.total))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                    if let prior = priorSummary {
                        Text(priorLabel(prior))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let prior = priorSummary {
                        ChangeBadge(change: PeriodCompare.change(
                            this: summary.total, last: prior.total))
                    }
                }
                HStack {
                    Text("价格覆盖").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((coverage * 100).rounded()))% · \(Fmt.tokensShort(summary.matchedTokens)) tokens")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                QuotaBar(progress: coverage, tint: coverage >= 0.95 ? Theme.hit : .orange)

                if !topAmounts.isEmpty {
                    ForEach(Array(topAmounts.enumerated()), id: \.element.id) { index, amount in
                        amountRow(rank: index + 1, amount: amount)
                    }
                }
                UnpricedModelsNote(names: summary.unpricedModels)
                if let conversionNote {
                    Text(conversionNote)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Divider()
                subscriptionSection

                Text(pricingPolicyText)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let coverageNote {
                    Text(coverageNote)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var topAmounts: [APIReferenceCostSummary.ModelAmount] {
        Array(summary.modelAmounts.prefix(3))
    }

    private func priorLabel(_ prior: APIReferenceCostSummary) -> String {
        let name: String
        switch range.fixedDayCount {
        case 1: name = "昨日"
        case 7: name = "前 7 天"
        case 30: name = "前 30 天"
        default: name = "上期"
        }
        return "\(name) \(Fmt.usd(prior.total))"
    }

    private func amountRow(rank: Int, amount: APIReferenceCostSummary.ModelAmount) -> some View {
        let share = summary.total > 0 ? amount.total / summary.total : 0
        return HStack(spacing: 7) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
                .frame(width: 14)
            Circle()
                .fill(amount.source?.overviewColor ?? Theme.brand)
                .frame(width: 6, height: 6)
            Text(amount.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if let source = amount.source {
                Text(source.overviewName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(source.overviewColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(source.overviewColor.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 4)
            Text("\(Fmt.usd(amount.total)) · \(Int((share * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        if let value = subscriptionValue {
            HStack {
                Text("订阅回本").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(value.multiple.map(SubscriptionValueSummary.multipleText) ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.brand)
            }
            Text(value.detailText)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !roiCurve.isEmpty {
                SubscriptionROITrendChart(points: roiCurve)
            }
        } else {
            Text("在「设置 → 订阅与费用」填写月费后，这里显示 API 等价是订阅费的几倍。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conversionNote: String? {
        guard summary.currency == "USD",
              let cny = summary.amounts.first(where: { $0.currency == "CNY" }),
              let rate = summary.conversionRates["CNY"],
              rate > 0 else { return nil }
        return String(
            format: "含人民币公开价 ¥%.2f，按固定参考汇率 $1 = ¥%.2f 折算。",
            cny.total,
            1 / rate
        )
    }

    private var pricingPolicyText: String {
        let sourceText: String
        if summary.sourceLabels.isEmpty {
            sourceText = "价格规则为 OpenRouter 优先，缺价时采用模型官方公开价"
        } else {
            sourceText = "按用量当日生效的 \(summary.sourceLabels.joined(separator: " + ")) 价格快照重算（最近核对 \(APIReferencePricingCatalog.observedAt)）"
        }
        return "\(sourceText)。仅表示 API 等价成本，不是订阅费、平台账单或历史成交价；运行时不联网。"
    }
}
