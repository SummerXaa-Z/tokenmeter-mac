import SwiftUI

// 来源页通用的「API 等价参考」卡，支持 周|近7天|月 切换（与同页历史环比
// 卡同窗口口径）。价格与总览同口径（按用量当日生效的快照重算），数据来自
// 实时采集的 dayModels + 本机留存的按天明细：自包含读取、不依赖实时采集
// 成功——工具没跑、本地路径暂时缺失时依然可见，从未有过明细时整卡隐藏
// （同 SourceWeekCompareCard 的承诺）。
struct SourceAPICostCard: View {
    let source: HistorySource
    let liveDayModels: [String: [String: ModelTokenTally]]?
    // 测试/渲染注入用；nil 时读本机设置（自包含，与 persisted 留存同思路）
    var subscriptionPlans: [SubscriptionPlan]? = nil
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
        let prior = SourceAPICost.priorSummary(
            source: source, liveDayModels: liveDayModels, period: period)
        let plans = subscriptionPlans ?? ConfigStore.shared.subscriptionPlans
        let subscription = SourceAPICost.subscriptionValue(
            source: source, liveDayModels: liveDayModels,
            period: period, plans: plans)
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
                    detail(summary, prior: prior, subscription: subscription)
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

    private func detail(
        _ summary: APIReferenceCostSummary,
        prior: APIReferenceCostSummary?,
        subscription: SubscriptionValueSummary?
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
            if let names = unpricedText(summary) {
                Text(names)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

// 来源页 7|30 天趋势图共用的悬停金额闭包：mmdd label → 当日 API 等价金额
// 文本。数据走 SourceAPICost.dailyValues（实时 dayModels 覆盖留存同一天），
// windowDays 与图表档位一致（7 天或 30 天）。
enum SourceHoverAmount {
    static func make(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        days: [String],   // 图中各桶的自然日键(YYYY-MM-DD)
        windowDays: Int = 7
    ) -> (String) -> String? {
        let values = SourceAPICost.dailyValues(
            source: source, liveDayModels: liveDayModels, windowDays: windowDays)
        let labels = Dictionary(uniqueKeysWithValues: days.map { (Fmt.mmdd($0), $0) })
        return { label in
            guard let key = labels[label], let value = values[key], value > 0 else { return nil }
            return Fmt.usd(value)
        }
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
        costSummary(
            source: source, liveDayModels: liveDayModels, period: period, prior: false,
            persisted: persisted, todayKey: todayKey, calendar: calendar)
    }

    /// 上期(上周/前 7 天/上月)的同口径金额,作环比徽标的基期。上期完整
    /// 落在过去,实时 dayModels 只覆盖最近 7 天,窗口外的天自动取留存。
    static func priorSummary(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        period: PeriodCompare.Period = .rolling7,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current
    ) -> APIReferenceCostSummary? {
        costSummary(
            source: source, liveDayModels: liveDayModels, period: period, prior: true,
            persisted: persisted, todayKey: todayKey, calendar: calendar)
    }

    private static func costSummary(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        period: PeriodCompare.Period,
        prior: Bool,
        persisted: [ModelUsageDay],
        todayKey: String,
        calendar: Calendar
    ) -> APIReferenceCostSummary? {
        guard let today = DateUtil.date(from: todayKey),
              let window = windowKeys(
                period: period, today: today, calendar: calendar, prior: prior),
              let merged = mergedDays(
                source: source, liveDayModels: liveDayModels,
                persisted: persisted, window: window),
              let summary = summary(from: samples(from: merged, source: source))
        else { return nil }
        return summary
    }

    /// 近 N 个自然日（含今天）逐日 API 等价美元金额（自然日键 → USD）：
    /// 来源页趋势图（7|30 天档）悬停说明行显示当日金额。合并口径与
    /// summary 一致，缺价模型不计入（该日金额为 0 时不建条目，说明行
    /// 自然不显示）。
    static func dailyValues(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current,
        windowDays: Int = 7
    ) -> [String: Double] {
        guard let today = DateUtil.date(from: todayKey),
              let window = dayWindowKeys(
                today: today, windowDays: windowDays, calendar: calendar),
              let merged = mergedDays(
                source: source, liveDayModels: liveDayModels,
                persisted: persisted, window: window)
        else { return [:] }
        var result: [String: Double] = [:]
        for date in merged.keys {
            let daySamples = samples(from: [date: merged[date] ?? [:]], source: source)
            if let summary = summary(from: daySamples), summary.total > 0 {
                result[date] = summary.total
            }
        }
        return result
    }

    /// 近 N 个自然日（含今天）的日期键集合：滚动窗口，不受日历周/月
    /// 边界影响。
    private static func dayWindowKeys(
        today: Date, windowDays: Int, calendar: Calendar
    ) -> Set<String>? {
        guard windowDays > 0 else { return nil }
        let todayStart = calendar.startOfDay(for: today)
        var keys = Set<String>()
        for offset in 0..<windowDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart)
            else { continue }
            keys.insert(DateUtil.key(date))
        }
        return keys.isEmpty ? nil : keys
    }

    /// 该来源当前周期的订阅回本：分母是设置里归属到该来源的订阅月费
    /// 合计，按窗口内自该来源明细覆盖起点以来的自然日折算（与总览的
    /// 摊法同思路——不拿没明细的天去摊成本）。未归属订阅或本期无明细
    /// 返回 nil，来源页不显示该区块。
    static func subscriptionValue(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        period: PeriodCompare.Period = .rolling7,
        plans: [SubscriptionPlan],
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current
    ) -> SubscriptionValueSummary? {
        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(plans, tagged: source)
        guard monthlyFee > 0,
              let today = DateUtil.date(from: todayKey),
              let summary = summary(
                source: source, liveDayModels: liveDayModels, period: period,
                persisted: persisted, todayKey: todayKey, calendar: calendar),
              let window = windowKeys(
                period: period, today: today, calendar: calendar, prior: false),
              let windowStart = window.min(),
              let coverageStart = coverageStart(
                source: source, liveDayModels: liveDayModels, persisted: persisted),
              let startDate = DateUtil.date(from: max(windowStart, coverageStart))
        else { return nil }
        let days = calendar.dateComponents([.day], from: startDate, to: today).day ?? 0
        return SubscriptionValueSummary(
            monthlyFeeUSD: monthlyFee, days: days + 1, apiValueUSD: summary.total)
    }

    /// 该来源最早有模型明细的一天（实时 + 留存合并取最早）：订阅费折算
    /// 天数的起点钳制，新装来源不满整周/整月时不拿空白天摊成本。
    private static func coverageStart(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay]
    ) -> String? {
        let persistedStart = persisted
            .filter { !($0.bySource[source]?.models.isEmpty ?? true) }
            .map(\.date).min()
        let liveStart = (liveDayModels ?? [:])
            .filter { date, models in
                ModelUsageHistoryStore.isDateKey(date)
                    && !(ModelTokenTally.nonEmpty(models)?.isEmpty ?? true)
            }
            .keys.min()
        return [persistedStart, liveStart].compactMap { $0 }.min()
    }

    /// 窗口内合并后的逐日模型明细：实时采集的 dayModels 覆盖留存明细的
    /// 同一天（不叠加），其余天取留存。
    private static func mergedDays(
        source: HistorySource,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay],
        window: Set<String>
    ) -> [String: [String: ModelTokenTally]]? {
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
        return merged.isEmpty ? nil : merged
    }

    private static func samples(
        from merged: [String: [String: ModelTokenTally]],
        source: HistorySource
    ) -> [APICostSample] {
        merged.sorted { $0.key < $1.key }.flatMap { date, models in
            models.keys.sorted().compactMap { model -> APICostSample? in
                guard let tally = models[model] else { return nil }
                return APICostSample(
                    model: model,
                    tokens: tally.breakdown,
                    usageDate: max(date, APIReferencePricingCatalog.firstObservedAt),
                    source: source)
            }
        }
    }

    private static func summary(
        from samples: [APICostSample]
    ) -> APIReferenceCostSummary? {
        guard !samples.isEmpty else { return nil }
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

    /// 窗口的日期键集合：本期从区间起点逐日到今天（日历周/月是截至今天
    /// 的部分周期，不包含未来日）；上期是完整周期，终点为区间排他边界。
    private static func windowKeys(
        period: PeriodCompare.Period,
        today: Date,
        calendar: Calendar,
        prior: Bool
    ) -> Set<String>? {
        guard let intervals = PeriodCompare.intervals(
            of: period, today: today, calendar: calendar)
        else { return nil }
        let interval = prior ? intervals.last : intervals.this
        let todayStart = calendar.startOfDay(for: today)
        var keys = Set<String>()
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor <= todayStart && cursor < interval.end {
            keys.insert(DateUtil.key(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys.isEmpty ? nil : keys
    }
}
