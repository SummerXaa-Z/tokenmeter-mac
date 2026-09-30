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
        var tokens: Int { tally.total }
    }

    struct Summary: Equatable {
        let source: HistorySource
        let model: String
        let tally: ModelTokenTally       // 窗口内合计
        let days: [DayValue]             // 升序、整窗口逐日（含补零天）
        let coverage: Double?            // 已计价 tokens 占比；窗口无明细为 nil

        var activeDays: Int { days.filter { !$0.tally.isEmpty }.count }
        var totalUSD: Double { days.reduce(0) { $0 + $1.usd } }
    }

    static func summary(
        source: HistorySource,
        model: String,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current,
        windowDays: Int = CodingModelDetail.windowDays
    ) -> Summary? {
        guard windowDays > 0,
              let today = DateUtil.date(from: todayKey)
        else { return nil }
        // 滚动窗口（含今天），与来源页 30 天档同口径
        let todayStart = calendar.startOfDay(for: today)
        var window: [String] = []
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart)
            else { return nil }
            window.append(DateUtil.key(date))
        }
        let windowSet = Set(window)

        // 同一天实时整天权威：该模型缺席即无用量（清掉留存旧值）
        var byDate: [String: ModelTokenTally] = [:]
        for day in persisted
        where windowSet.contains(day.date) && ModelUsageHistoryStore.isDateKey(day.date) {
            if let tally = day.bySource[source]?.models[model], !tally.isEmpty {
                byDate[day.date] = tally
            }
        }
        for (date, models) in liveDayModels ?? [:] where windowSet.contains(date) {
            if let tally = models[model], !tally.isEmpty {
                byDate[date] = tally
            } else {
                byDate.removeValue(forKey: date)
            }
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
                estimator: APIReferencePricingCatalog.estimator,
                referenceDate: APIReferencePricingCatalog.observedAt,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
            return DayValue(date: date, usd: daySummary.total, tally: dayTally)
        }
        let whole = APIReferenceCostSummary(
            samples: samples,
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
        return Summary(
            source: source, model: model, tally: tally,
            days: days, coverage: whole.coverage)
    }
}
