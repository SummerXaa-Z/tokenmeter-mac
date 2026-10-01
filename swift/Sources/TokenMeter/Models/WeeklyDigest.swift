import Foundation

// 每周一条的"上周用量摘要"通知:上周全部 Coding 来源 Token 合计、环比、
// 主力来源、模型 Top3、API 等价金额与订阅回本倍数(附近几周走势小抄)。
// 数据与总览环比卡同源(PeriodCompare 日历周口径),金额按天明细 + 当日
// 生效价重算(与总览 API 等价同口径),纯本地计算,经 Notifier 推系统
// 通知;上周一条记录都没有就不打扰。
enum WeeklyDigest {
    struct Message: Equatable {
        let title: String
        let body: String
    }

    /// ISO 年-周标识(如 2026-W39),作为"本周已发过"的去重键。
    static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(
            format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// 周一到周三、早上 9 点后、本周还没发过 → 该发。App 周一整天没开机时,
    /// 周二/周三的首次刷新仍会补发上周摘要,更晚就等下一周。
    static func isDue(
        lastSentWeek: String?,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let weekday = calendar.component(.weekday, from: today)
        guard (2...4).contains(weekday),   // 2=周一 ... 4=周三
              calendar.component(.hour, from: today) >= 9
        else { return false }
        return lastSentWeek != weekKey(today, calendar: calendar)
    }

    /// 上周摘要文案:按 ISO 周键(与趋势图周桶一致)直接取"上周""上上周"
    /// 两个整周桶,环比复用 PeriodCompare 的口径。上周无任何用量返回 nil。
    /// 不走 DateInterval 边界判断——Darwin 的 contains 把 end 视作闭端,
    /// 回退一周复用区间时会把边界日(今天)误计进上周。
    /// API 等价金额取按天模型明细(v3.12 起留存):没有明细的早期历史只报
    /// Token,金额段自动省略。
    static func message(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        modelDays: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        plans: [SubscriptionPlan] = [],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Message? {
        let allowed = Set(participants)
        guard let lastWeek = calendar.date(byAdding: .day, value: -7, to: today),
              let priorWeek = calendar.date(byAdding: .day, value: -14, to: today)
        else { return nil }
        let lastKey = weekKey(lastWeek, calendar: calendar)
        let priorKey = weekKey(priorWeek, calendar: calendar)

        var lastBySource: [HistorySource: Int] = [:]
        var priorBySource: [HistorySource: Int] = [:]
        for day in days {
            guard let date = DateUtil.date(from: day.date) else { continue }
            let key = weekKey(date, calendar: calendar)
            guard key == lastKey || key == priorKey else { continue }
            for (source, tokens) in day.bySource where allowed.contains(source) {
                if key == lastKey {
                    lastBySource[source, default: 0] += tokens
                } else {
                    priorBySource[source, default: 0] += tokens
                }
            }
        }

        let lastTotal = lastBySource.values.reduce(0, +)
        let priorTotal = priorBySource.values.reduce(0, +)
        guard lastTotal > 0 else { return nil }

        var body = "合计 \(Fmt.tokensShort(lastTotal))"
        if let change = PeriodCompare.change(this: lastTotal, last: priorTotal) {
            body += "，环比 \(change >= 0 ? "↑" : "↓") \(Fmt.percent(abs(change)))"
        }
        let top = lastBySource.max { $0.value < $1.value }
        if let top {
            if lastBySource.count > 1 {
                let share = Double(top.value) / Double(lastTotal) * 100
                body += "；主力 \(top.key.overviewName) \(Fmt.percent(share))"
            } else {
                body += "；全部来自 \(top.key.overviewName)"
            }
        }
        if let models = topModelsText(
            modelDays, allowed: allowed, lastKey: lastKey, calendar: calendar)
        {
            body += "；\(models)"
        }
        let amounts = weeklyAmounts(
            modelDays, allowed: allowed, lastKey: lastKey, priorKey: priorKey,
            calendar: calendar)
        if let last = amounts.last, last.matchedTokens > 0 {
            body += "；API 等价 \(Fmt.usd(last.total))"
            if let change = PeriodCompare.change(
                this: last.total, last: amounts.prior?.total ?? 0)
            {
                body += "（环比 \(change >= 0 ? "↑" : "↓") \(Fmt.percent(abs(change)))）"
            }
            if let coverage = last.coverage, coverage < 0.999 {
                body += "，价格覆盖 \(Int((coverage * 100).rounded()))%"
            }
            // 金额段必附价格新鲜度;覆盖不足时点名缺价模型,方便报给收录流程
            body += "，最近核对 \(APIReferencePricingCatalog.observedAt)"
            if let coverage = last.coverage, coverage < 0.95,
               !last.unpricedModels.isEmpty
            {
                let listed = last.unpricedModels.prefix(2).joined(separator: "、")
                let suffix = last.unpricedModels.count > 2 ? " 等" : ""
                body += "，缺价 \(listed)\(suffix)"
            }
            if let value = subscriptionValue(
                apiValueUSD: last.total, modelDays: modelDays, allowed: allowed,
                lastWeekDate: lastWeek, plans: plans, calendar: calendar),
               let multiple = value.multiple
            {
                body += "；订阅回本 \(SubscriptionValueSummary.multipleText(multiple))"
                if let trend = roiTrendText(
                    modelDays: modelDays, allowed: allowed,
                    plans: plans, today: today, calendar: calendar)
                {
                    body += "，\(trend)"
                }
            }
        }
        return Message(title: "TokenMeter 上周用量摘要", body: body)
    }

    /// 上周模型 Top3 小抄:按天明细里逐模型合计(跨参与来源合并同名模型),
    /// 取前三名与份额;单个模型只报名字,明细没覆盖上周时整段省略。
    /// 份额分母为上周有明细的模型合计(与金额段同一条明细管线)。
    /// 同名同量按模型名字典序定先后,通知文案可复现。
    private static func topModelsText(
        _ modelDays: [ModelUsageDay],
        allowed: Set<HistorySource>,
        lastKey: String,
        calendar: Calendar
    ) -> String? {
        var byModel: [String: Int] = [:]
        for day in modelDays {
            guard let date = DateUtil.date(from: day.date),
                  weekKey(date, calendar: calendar) == lastKey
            else { continue }
            for (source, detail) in day.bySource where allowed.contains(source) {
                for (model, tally) in detail.models where !tally.isEmpty {
                    byModel[model, default: 0] += tally.total
                }
            }
        }
        let total = byModel.values.reduce(0, +)
        guard total > 0 else { return nil }
        let ranked = byModel.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        guard ranked.count > 1 else { return "模型 \(ranked[0].key)" }
        let leaders = ranked.prefix(3).map { entry in
            "\(entry.key) \(Fmt.percent(Double(entry.value) / Double(total) * 100))"
        }
        return "模型 Top3 " + leaders.joined(separator: "、")
    }

    /// 回本走势小抄:近几个完整周的逐周倍数(如"近 4 周 1.8 → 2.4 → 2.1 →
    /// 2.0"),与正文回本倍数同一条曲线(总览口径,全部订阅合计),末位即
    /// 刚报的倍数。分母自留存起点起逐周连续,有数据的周必然连成一段并
    /// 终于上周,所以"近 N 周"字面成立;不足两个周不拼——单个数成不了
    /// 走势。
    private static func roiTrendText(
        modelDays: [ModelUsageDay],
        allowed: Set<HistorySource>,
        plans: [SubscriptionPlan],
        today: Date,
        calendar: Calendar
    ) -> String? {
        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(plans)
        guard monthlyFee > 0 else { return nil }
        let recent = SubscriptionROICurve.weeklyPoints(
            participants: allowed, monthlyFeeUSD: monthlyFee,
            persisted: modelDays, today: today, calendar: calendar)
            .compactMap(\.multiple)
            .suffix(4)
        guard recent.count >= 2 else { return nil }
        let items = recent.map { String(format: "%.1f", $0) }
        return "近 \(recent.count) 周 " + items.joined(separator: " → ")
    }

    /// 上周的订阅回本:分母为全部订阅月费合计(总览口径,人民币按固定参考
    /// 汇率折算),按上周自然日折算;明细留存起点落在周内时不拿之前的空白
    /// 天摊(与来源页回本同钳制)。未填订阅或无按天明细返回 nil,段省略。
    private static func subscriptionValue(
        apiValueUSD: Double,
        modelDays: [ModelUsageDay],
        allowed: Set<HistorySource>,
        lastWeekDate: Date,
        plans: [SubscriptionPlan],
        calendar: Calendar
    ) -> SubscriptionValueSummary? {
        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(plans)
        guard monthlyFee > 0 else { return nil }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        iso.firstWeekday = 2
        guard let week = iso.dateInterval(of: .weekOfYear, for: lastWeekDate)
        else { return nil }
        let weekStart = calendar.startOfDay(for: week.start)
        guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart)
        else { return nil }
        let coverageStart = modelDays
            .filter { day in
                ModelUsageHistoryStore.isDateKey(day.date)
                    && day.bySource.contains { allowed.contains($0.key) && !$0.value.models.isEmpty }
            }
            .map(\.date).min()
        guard let coverageStart,
              let startDate = DateUtil.date(from: max(DateUtil.key(weekStart), coverageStart)),
              let endDate = DateUtil.date(from: DateUtil.key(weekEnd))
        else { return nil }
        let days = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        return SubscriptionValueSummary(
            monthlyFeeUSD: monthlyFee, days: days + 1, apiValueUSD: apiValueUSD)
    }

    /// 上周/上上周的 API 等价金额:按天明细逐日取样,价格取用量当日已生效
    /// 的快照(首个快照之前的用量按首快照计价),与总览同口径。
    private static func weeklyAmounts(
        _ modelDays: [ModelUsageDay],
        allowed: Set<HistorySource>,
        lastKey: String,
        priorKey: String,
        calendar: Calendar
    ) -> (last: APIReferenceCostSummary?, prior: APIReferenceCostSummary?) {
        var buckets: [String: [APICostSample]] = [lastKey: [], priorKey: []]
        for day in modelDays {
            guard let date = DateUtil.date(from: day.date) else { continue }
            let key = weekKey(date, calendar: calendar)
            guard buckets[key] != nil else { continue }
            for (source, detail) in day.bySource where allowed.contains(source) {
                for (model, tally) in detail.models where !tally.isEmpty {
                    buckets[key]?.append(APICostSample(
                        model: model,
                        tokens: tally.breakdown,
                        usageDate: max(day.date, APIReferencePricingCatalog.firstObservedAt),
                        source: source))
                }
            }
        }
        func summary(_ samples: [APICostSample]) -> APIReferenceCostSummary? {
            guard !samples.isEmpty else { return nil }
            return APIReferenceCostSummary(
                samples: samples,
                estimator: APIReferencePricingCatalog.estimator,
                referenceDate: APIReferencePricingCatalog.observedAt,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
        }
        return (summary(buckets[lastKey] ?? []), summary(buckets[priorKey] ?? []))
    }

    /// 设置里已启用的 Coding 来源(DeepSeek 平台账户天然不在其列)。
    static func participants(_ store: ConfigStore) -> [HistorySource] {
        [
            store.claudeMonitorEnabled ? .claude : nil,
            store.codexMonitorEnabled ? .codex : nil,
            store.kimiMonitorEnabled ? .kimi : nil,
            store.opencodeMonitorEnabled ? .opencode : nil,
            store.geminiMonitorEnabled ? .gemini : nil,
            store.copilotMonitorEnabled ? .copilot : nil,
            store.qwenMonitorEnabled ? .qwen : nil,
            store.cursorMonitorEnabled ? .cursor : nil,
        ].compactMap { $0 }
    }
}
