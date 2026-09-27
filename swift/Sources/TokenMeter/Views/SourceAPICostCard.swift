import SwiftUI

// 来源页通用的「API 等价参考」卡，支持 周|近7天|月 切换（与同页历史环比
// 卡同窗口口径）。价格与总览同口径（按用量当日生效的快照重算），数据来自
// 实时采集的 dayModels + 本机留存的按天明细：自包含读取、不依赖实时采集
// 成功——工具没跑、本地路径暂时缺失时依然可见，从未有过明细时整卡隐藏
// （同 SourceWeekCompareCard 的承诺）。
struct SourceAPICostCard: View {
    let source: HistorySource
    let liveDayModels: [String: [String: ModelTokenTally]]?
    @State private var period: PeriodCompare.Period = .week

    var body: some View {
        let used = SourceAPICost.everUsed(source: source, liveDayModels: liveDayModels)
        return Group {
            if used {
                content
            }
        }
    }

    private var content: some View {
        let summary = SourceAPICost.summary(
            source: source, liveDayModels: liveDayModels, period: period)
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
                    detail(summary)
                } else {
                    // 有历史但所选周期暂无明细（如本周还没用过）：提示而非
                    // 整卡消失，切档后数字自然回来（与环比卡同语义）
                    Text("本周期暂无该来源用量明细")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(_ summary: APIReferenceCostSummary) -> some View {
        let coverage = summary.coverage ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.amounts.isEmpty ? "暂无参考价" : Fmt.usd(summary.total))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brand)
                Spacer()
                Text("价格覆盖 \(Int((coverage * 100).rounded()))% · \(Fmt.tokensShort(summary.matchedTokens)) tokens")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            QuotaBar(progress: coverage, tint: coverage >= 0.95 ? Theme.hit : .orange)

            ForEach(Array(summary.modelAmounts.prefix(3).enumerated()), id: \.element.id) {
                index, amount in
                amountRow(rank: index + 1, amount: amount, total: summary.total)
            }
            if let names = unpricedText(summary) {
                Text(names)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let conversion = conversionNote(summary) {
                Text(conversion)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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

    private func unpricedText(_ summary: APIReferenceCostSummary) -> String? {
        let names = summary.unpricedModels
        guard !names.isEmpty else { return nil }
        let listed = names.prefix(3).joined(separator: "、")
        let suffix = names.count > 3 ? " 等" : ""
        return "另有 \(names.count) 个模型缺少参考价，未计入金额：\(listed)\(suffix)"
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

// 单来源的 API 等价汇总：窗口口径与来源页历史环比卡一致（周=ISO 日历周、
// 月=自然月，本期均截至今天；近 7 天为滚动窗口），实时采集的 dayModels
// 覆盖留存明细的同一天（不叠加），其余天取本机留存；首个价格快照之前的
// 用量按首个快照计价。
enum SourceAPICost {
    static func summary(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        period: PeriodCompare.Period = .rolling7,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current
    ) -> APIReferenceCostSummary? {
        guard let today = DateUtil.date(from: todayKey),
              let window = windowKeys(period: period, today: today, calendar: calendar)
        else { return nil }

        var merged: [String: [String: ModelTokenTally]] = [:]
        for day in persisted
        where window.contains(day.date) && ModelUsageHistoryStore.isDateKey(day.date) {
            for (model, tally) in day.bySource[source]?.models ?? [:] where !tally.isEmpty {
                merged[day.date, default: [:]][model] = tally
            }
        }
        for (date, models) in liveDayModels ?? [:] where window.contains(date) {
            merged[date] = ModelTokenTally.nonEmpty(models) ?? [:]
        }
        merged = merged.filter { !$0.value.isEmpty }
        guard !merged.isEmpty else { return nil }

        let samples: [APICostSample] = merged.sorted { $0.key < $1.key }.flatMap { date, models in
            models.keys.sorted().compactMap { model -> APICostSample? in
                guard let tally = models[model] else { return nil }
                return APICostSample(
                    model: model,
                    tokens: tally.breakdown,
                    usageDate: max(date, APIReferencePricingCatalog.firstObservedAt),
                    source: source)
            }
        }
        return APIReferenceCostSummary(
            samples: samples,
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
    }

    /// 该来源是否曾有过模型明细（不限窗口）：决定整卡是否隐藏。某档窗口
    /// 暂无明细不算从未使用——切档或等到下周数字会回来，提示而非消失。
    static func everUsed(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all()
    ) -> Bool {
        if let live = liveDayModels, live.values.contains(where: { !$0.isEmpty }) {
            return true
        }
        return persisted.contains { !($0.bySource[source]?.models.isEmpty ?? true) }
    }

    /// 本期窗口的日期键集合：从区间起点逐日到今天（日历周/月是截至今天
    /// 的部分周期，不包含未来日）。
    private static func windowKeys(
        period: PeriodCompare.Period,
        today: Date,
        calendar: Calendar
    ) -> Set<String>? {
        guard let interval = PeriodCompare.intervals(
            of: period, today: today, calendar: calendar)?.this
        else { return nil }
        let todayStart = calendar.startOfDay(for: today)
        var keys = Set<String>()
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor <= todayStart {
            keys.insert(DateUtil.key(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys.isEmpty ? nil : keys
    }
}
