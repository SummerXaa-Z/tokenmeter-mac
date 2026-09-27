import Foundation

// 用量历史 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 列固定为 日期 + Coding 来源（不含 DeepSeek 平台）+ Coding 合计 + 平台 Token
// + 平台费用 + API 等价；按日期升序，任何输入顺序都产出稳定结果。
// API 等价只在当天有模型明细时填写，留空表示无明细（不是 0 元）。
// 末尾附「汇总」行（各列求和，与表头同列对齐）；填写了订阅月费时再附
// 「订阅回本」行——月费合计、按导出跨度折算的天数与订阅费、API 等价
// 合计与回本倍数，与总览同口径。
enum UsageCSVExport {
    private static let codingColumns: [(source: HistorySource, title: String)] = [
        (.claude, "Claude"), (.codex, "Codex"), (.kimi, "Kimi"),
        (.opencode, "OpenCode"), (.gemini, "Gemini"), (.copilot, "Copilot"),
        (.qwen, "Qwen Code"), (.cursor, "Cursor"),
    ]

    static func makeCSV(
        _ days: [HistoryStore.DayPoint],
        apiValueByDate: [String: Double] = [:],
        modelHistory: [ModelUsageDay] = [],
        plans: [SubscriptionPlan] = []
    ) -> String {
        var lines = [[String]]()
        lines.append(["日期"]
            + codingColumns.map(\.title)
            + ["Coding 合计", "DeepSeek 平台", "平台费用(USD)", "API 等价(USD)"])
        let sorted = days.sorted(by: { $0.date < $1.date })
        for day in sorted {
            let codingTotal = HistorySource.codingAgents.reduce(0) {
                $0 + (day.bySource[$1] ?? 0)
            }
            lines.append([day.date]
                + codingColumns.map { String(day.bySource[$0.source] ?? 0) }
                + [
                    String(codingTotal),
                    String(day.bySource[.deepseek] ?? 0),
                    String(format: "%.2f", day.cost),
                    apiValueByDate[day.date].map { String(format: "%.2f", $0) } ?? "",
                ])
        }
        if !sorted.isEmpty {
            lines.append(totalRow(sorted, apiValueByDate: apiValueByDate))
        }
        if let subscription = subscriptionSummary(
            sorted, apiValueByDate: apiValueByDate,
            modelHistory: modelHistory, plans: plans)
        {
            lines.append([
                "订阅回本",
                String(format: "订阅月费合计(USD) %.2f", subscription.monthlyFeeUSD),
                "折算天数 \(subscription.days)",
                String(format: "折算订阅费(USD) %.2f", subscription.proratedFeeUSD),
                String(format: "API 等价合计(USD) %.2f", subscription.apiValueUSD),
                subscription.multiple.map { String(format: "回本倍数 %.2f", $0) } ?? "回本倍数 —",
            ])
        }
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// 「汇总」行：逐列求和（平台费用与 API 等价同口径相加），与表头对齐。
    private static func totalRow(
        _ sorted: [HistoryStore.DayPoint], apiValueByDate: [String: Double]
    ) -> [String] {
        var bySource = [HistorySource: Int]()
        var cost = 0.0
        for day in sorted {
            for (source, tokens) in day.bySource {
                bySource[source, default: 0] += tokens
            }
            cost += day.cost
        }
        let codingTotal = HistorySource.codingAgents.reduce(0) {
            $0 + (bySource[$1] ?? 0)
        }
        let apiTotal = sorted.compactMap { apiValueByDate[$0.date] }.reduce(0, +)
        return ["汇总"]
            + codingColumns.map { String(bySource[$0.source] ?? 0) }
            + [
                String(codingTotal),
                String(bySource[.deepseek] ?? 0),
                String(format: "%.2f", cost),
                String(format: "%.2f", apiTotal),
            ]
    }

    /// 「订阅回本」行的数字：月费为全部订阅合计（人民币按固定参考汇率折算）；
    /// 折算天数从导出起点与按天明细留存起点中较晚者数到导出终点——不拿
    /// 没算进金额的天去摊订阅费（与总览/来源页同钳制）。
    private static func subscriptionSummary(
        _ sorted: [HistoryStore.DayPoint],
        apiValueByDate: [String: Double],
        modelHistory: [ModelUsageDay],
        plans: [SubscriptionPlan]
    ) -> SubscriptionValueSummary? {
        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(plans)
        guard monthlyFee > 0,
              let exportStart = sorted.first?.date,
              let exportEnd = sorted.last?.date,
              let startDate = DateUtil.date(
                from: max(exportStart, detailCoverageStart(modelHistory) ?? exportStart)),
              let endDate = DateUtil.date(from: exportEnd)
        else { return nil }
        let days = Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        let apiTotal = apiValueByDate.values.reduce(0, +)
        return SubscriptionValueSummary(
            monthlyFeeUSD: monthlyFee, days: days + 1, apiValueUSD: apiTotal)
    }

    /// 最早有按天模型明细的一天（任意 Coding 来源）。
    private static func detailCoverageStart(_ modelHistory: [ModelUsageDay]) -> String? {
        modelHistory
            .filter { day in
                ModelUsageHistoryStore.isDateKey(day.date)
                    && day.bySource.contains { $0.key.isCodingAgent && !$0.value.models.isEmpty }
            }
            .map(\.date).min()
    }

    // 每天全部 Coding 来源的 API 等价金额（USD），与总览同一价格口径：
    // 首个快照之前的用量按首个快照计价，此后按用量当日生效价。
    static func apiValueByDate(_ modelHistory: [ModelUsageDay]) -> [String: Double] {
        var result: [String: Double] = [:]
        for day in modelHistory {
            let pricingDate = max(day.date, APIReferencePricingCatalog.firstObservedAt)
            let samples = HistorySource.codingAgents.flatMap { source in
                (day.bySource[source]?.models ?? [:]).map { model, tally in
                    APICostSample(
                        model: model, tokens: tally.breakdown,
                        usageDate: pricingDate, source: source)
                }
            }
            guard !samples.isEmpty else { continue }
            let summary = APIReferenceCostSummary(
                samples: samples,
                estimator: APIReferencePricingCatalog.estimator,
                referenceDate: pricingDate,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
            // 当天模型全部缺价时留空，不写成 0 元
            guard !summary.amounts.isEmpty else { continue }
            result[day.date] = summary.total
        }
        return result
    }

    static func suggestedFilename() -> String {
        "TokenMeter-usage-\(DateUtil.today()).csv"
    }
}
