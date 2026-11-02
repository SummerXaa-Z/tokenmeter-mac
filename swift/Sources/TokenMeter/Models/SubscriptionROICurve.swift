import Foundation

// 订阅回本走势：近 N 个完整周（周一到周日）逐周回本倍数。
// 分子 = 周内已计价 API 等价合计（与热力图悬停金额同一条计价管线）；
// 分母 = 周内自然日摊到的订阅费（月费 × 12/365 × 天数），起点不早于
// 按天明细留存起点——没有明细的日子不摊，与总览回本口径一致。
// 含今天的本周不计：部分周的倍数会被小分母放大，误读成暴跌。
enum SubscriptionROICurve {
    struct WeekPoint: Equatable, Identifiable {
        let weekOf: String       // 周一日期键 yyyy-MM-dd
        let apiValueUSD: Double
        let feeUSD: Double
        var apiValueKnown: Bool = true
        var priceCoverage: Double? = nil

        var multiple: Double? { feeUSD > 0 && apiValueKnown ? apiValueUSD / feeUSD : nil }
        var pricedValueUSD: Double? { apiValueKnown ? apiValueUSD : nil }
        var isPartial: Bool { priceCoverage.map { $0 < 0.999 } == true }
        var id: String { weekOf }
    }

    static let defaultWeeks = 13

    /// weeks 个完整周（不含本周）的逐周回本点，按时间升序。
    /// 留存起点之前的周 feeUSD 为 0（multiple 为 nil，图表上自然断线）。
    static func weeklyPoints(
        participants: some Sequence<HistorySource>,
        monthlyFeeUSD: Double,
        persisted: [ModelUsageDay],
        dailyHistory: [HistoryStore.DayPoint] = [],
        today: Date = Date(),
        weeks: Int = defaultWeeks,
        calendar: Calendar = .current
    ) -> [WeekPoint] {
        guard monthlyFeeUSD > 0, weeks > 0 else { return [] }
        let allowed = Set(participants)
        guard allowed.contains(where: \.isCodingAgent) else { return [] }
        let todayKey = DateUtil.key(today)

        // 分母的覆盖起点：最早一条属于参与来源的按天明细
        var coverageStart: String?
        for day in persisted
        where day.date <= todayKey && ModelUsageHistoryStore.isDateKey(day.date) {
            let hasDetail = day.bySource.contains {
                allowed.contains($0.key) && !$0.value.models.isEmpty
            }
            guard hasDetail else { continue }
            if let seen = coverageStart, day.date >= seen { continue }
            coverageStart = day.date
        }
        guard let coverageStart else { return [] }

        let thisMonday = UsageHeatmap.mondayKey(of: today, calendar: calendar)
        let mondayDate = DateUtil.date(from: thisMonday) ?? calendar.startOfDay(for: today)
        let dailyFee = monthlyFeeUSD * 12 / 365

        var points: [WeekPoint] = []
        for index in stride(from: weeks, through: 1, by: -1) {
            guard let monday = calendar.date(
                byAdding: .weekOfYear, value: -index, to: mondayDate),
                let sunday = calendar.date(
                    byAdding: .day, value: 6, to: monday)
            else { continue }
            var feeDays = 0
            var cursor = monday
            while cursor <= sunday {
                let key = DateUtil.key(cursor)
                if key >= coverageStart, key <= todayKey { feeDays += 1 }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            let startKey = DateUtil.key(monday), endKey = DateUtil.key(sunday)
            let weekModels = persisted.filter { $0.date >= startKey && $0.date <= endKey }
            let weekDaily = dailyHistory.filter { $0.date >= startKey && $0.date <= endKey }
            let missing = ModelUsageCoverage.unmodelledTokens(
                dailyHistory: weekDaily, modelHistory: weekModels,
                participants: allowed, through: todayKey)
            let samples = weekModels
                .flatMap { day in
                    day.bySource.filter { allowed.contains($0.key) }.flatMap { source, detail in
                        detail.models.map { model, tally in
                            APICostSample(model: model, tokens: tally.breakdown,
                                usageDate: max(day.date, APIReferencePricingCatalog.firstObservedAt), source: source)
                        }
                    }
                }
            let summary = APIReferenceCostSummary(
                samples: samples, estimator: APIReferencePricingCatalog.estimator,
                referenceDate: APIReferencePricingCatalog.observedAt,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD,
                unmodelledTokens: missing)
            points.append(WeekPoint(
                weekOf: DateUtil.key(monday),
                apiValueUSD: summary.total,
                feeUSD: dailyFee * Double(feeDays),
                apiValueKnown: summary.pricedTotal != nil,
                priceCoverage: summary.coverage))
        }
        return points
    }
}
