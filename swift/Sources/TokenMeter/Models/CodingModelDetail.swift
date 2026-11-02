import Foundation

// 单个 Coding 模型的近 N 天下钻：Token 构成与逐日 API 等价金额。
// 合并口径与总览模型榜、来源页 30 天趋势同源——实时采集的 dayModels
// 整天覆盖留存明细的同一天（该模型当天缺席即无用量，不叠加），其余天
// 取本机留存；金额走「API 等价参考」同一条当日生效价管线，缺价或价格
// 未生效的用量不计入金额（覆盖率如实降低，金额只偏低不虚高）。
enum CodingModelDetail {
    static let windowDays = 30

    struct DayValue: Equatable {
        let date: String           // 自然日键 yyyy-MM-dd
        let usd: Double            // 当日该模型 API 等价；0 = 无计价金额
        let tally: ModelTokenTally // 当日该模型五类 Token；空 = 无用量
        var hasPrice: Bool = true
        var tokens: Int { tally.total }
        var pricedUSD: Double? { hasPrice ? usd : nil }
    }

    struct Summary: Equatable {
        let source: HistorySource
        let model: String
        let tally: ModelTokenTally       // 窗口内合计
        let days: [DayValue]             // 升序、整窗口逐日（含补零天）
        let coverage: Double?            // 已计价 tokens 占比；窗口无明细为 nil

        var activeDays: Int { days.filter { !$0.tally.isEmpty }.count }
        var totalUSD: Double { days.reduce(0) { $0 + $1.usd } }
        var pricedTotalUSD: Double? {
            days.contains { $0.tokens > 0 && $0.hasPrice } ? totalUSD : nil
        }
    }

    static func summary(
        source: HistorySource,
        model: String,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay] = [],
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current,
        windowDays: Int = CodingModelDetail.windowDays,
        allHistory: Bool = false,
        estimator: APICostEstimator = APIReferencePricingCatalog.estimator
    ) -> Summary? {
        guard (windowDays > 0 || allHistory),
              let today = DateUtil.date(from: todayKey)
        else { return nil }
        // 同一天实时整天权威：该模型缺席即无用量（清掉留存旧值）
        var byDate: [String: ModelTokenTally] = [:]
        for day in persisted
        where day.date <= todayKey && ModelUsageHistoryStore.isDateKey(day.date) {
            guard let detail = day.bySource[source] else { continue }
            if let tally = detail.models[model], !tally.isEmpty {
                byDate[day.date] = tally
            } else {
                byDate.removeValue(forKey: day.date)
            }
        }
        for (date, models) in liveDayModels ?? [:]
        where date <= todayKey && ModelUsageHistoryStore.isDateKey(date) {
            if let tally = models[model], !tally.isEmpty {
                byDate[date] = tally
            } else {
                byDate.removeValue(forKey: date)
            }
        }

        // ALL is the model's actual retained history, not an implicit 30/90-day
        // substitute. Build its continuous calendar only after live replacement.
        let todayStart = calendar.startOfDay(for: today)
        let count: Int
        if allHistory {
            guard let first = byDate.keys.min(), let start = DateUtil.date(from: first) else { return nil }
            count = (calendar.dateComponents([.day], from: start, to: todayStart).day ?? 0) + 1
        } else {
            count = windowDays
        }
        guard count > 0 else { return nil }
        var window: [String] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            window.append(DateUtil.key(date))
        }

        var tally = ModelTokenTally()
        var samples: [APICostSample] = []
        for date in window {
            guard let dayTally = byDate[date], !dayTally.isEmpty else { continue }
            tally += dayTally
            samples.append(APICostSample(
                model: model,
                tokens: dayTally.breakdown,
                usageDate: max(date, APIReferencePricingCatalog.firstObservedAt),
                source: source))
        }
        guard !samples.isEmpty else { return nil }

        let days = window.map { date -> DayValue in
            guard let dayTally = byDate[date], !dayTally.isEmpty else {
                return DayValue(date: date, usd: 0, tally: ModelTokenTally())
            }
            let daySummary = APIReferenceCostSummary(
                samples: [APICostSample(
                    model: model,
                    tokens: dayTally.breakdown,
                    usageDate: max(date, APIReferencePricingCatalog.firstObservedAt),
                    source: source)],
                estimator: estimator,
                referenceDate: APIReferencePricingCatalog.observedAt,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
            return DayValue(date: date, usd: daySummary.total, tally: dayTally,
                            hasPrice: daySummary.pricedTotal != nil)
        }
        let whole = APIReferenceCostSummary(
            samples: samples,
            estimator: estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
        return Summary(
            source: source, model: model, tally: tally,
            days: days, coverage: whole.coverage)
    }

    struct TrendValue: Equatable {
        let key: String
        let label: String
        let tally: ModelTokenTally
        let pricedUSD: Double?
        let isPartial: Bool
        var tokens: Int { tally.total }
    }

    // The chart and CSV consume the same optional price. An all-unpriced bucket
    // remains unknown; known free usage and no-token buckets remain real zero.
    static func trendValues(
        from days: [DayValue], granularity: UsageTrendGranularity,
        calendar: Calendar = .current
    ) -> [TrendValue] {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        var grouped: [String: (tally: ModelTokenTally, usd: Double, priced: Int, missing: Int)] = [:]
        for day in days {
            guard ModelUsageHistoryStore.isDateKey(day.date), let date = DateUtil.date(from: day.date) else { continue }
            let key: String
            switch granularity {
            case .hour, .day: key = day.date
            case .week: key = DateUtil.key(iso.dateInterval(of: .weekOfYear, for: date)?.start ?? date)
            case .month:
                key = DateUtil.key(calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date)
            }
            var slot = grouped[key] ?? (ModelTokenTally(), 0, 0, 0)
            slot.tally += day.tally
            if let amount = day.pricedUSD {
                slot.usd += amount
                if day.tokens > 0 { slot.priced += 1 }
            } else if day.tokens > 0 {
                slot.missing += 1
            }
            grouped[key] = slot
        }
        return grouped.keys.sorted().compactMap { key in
            guard let slot = grouped[key] else { return nil }
            let label = granularity == .month ? Fmt.ym(key)
                : granularity == .week ? "\(Fmt.mmdd(key))周" : Fmt.mmdd(key)
            return TrendValue(key: key, label: label, tally: slot.tally,
                pricedUSD: slot.priced > 0 || slot.tally.isEmpty ? slot.usd : nil,
                isPartial: slot.priced > 0 && slot.missing > 0)
        }
    }

    // 90 天档的趋势图按自然周聚合（与总览「全部」范围的周粒度同口径：
    // ISO 周历、周一为界），首尾周可能不足整周（窗口是含今天的滚动窗）。
    struct WeekValue: Equatable {
        let weekStart: String      // 该周周一 yyyy-MM-dd
        let usd: Double            // 周内合计 API 等价
        let tally: ModelTokenTally // 周内合计五类 Token
        var hasPrice: Bool = true
        var tokens: Int { tally.total }
        var pricedUSD: Double? { hasPrice ? usd : nil }
    }

    static func weeklyBuckets(
        from days: [DayValue],
        calendar: Calendar = .current
    ) -> [WeekValue] {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        var order: [String] = []
        var byWeek: [String: (usd: Double, tally: ModelTokenTally, priced: Bool)] = [:]
        for day in days {
            guard let date = DateUtil.date(from: day.date),
                  let start = iso.dateInterval(of: .weekOfYear, for: date)?.start
            else { continue }
            let key = DateUtil.key(start)
            if byWeek[key] == nil { order.append(key) }
            let slot = byWeek[key] ?? (usd: 0, tally: ModelTokenTally(), priced: false)
            byWeek[key] = (slot.usd + day.usd, slot.tally + day.tally,
                          slot.priced || day.tokens > 0 && day.hasPrice)
        }
        // days 升序 → order 升序；空周不补位（滚动窗口首尾本来就可能缺天）
        return order.map { key in
            WeekValue(
                weekStart: key,
                usd: byWeek[key]?.usd ?? 0,
                tally: byWeek[key]?.tally ?? ModelTokenTally(),
                hasPrice: byWeek[key]?.priced == true || byWeek[key]?.tally.isEmpty == true)
        }
    }
}
