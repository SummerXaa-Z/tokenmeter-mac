import Foundation

// 用量历史 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 列固定为 日期 + Coding 来源（不含 DeepSeek 平台）+ Coding 合计 + 平台 Token
// + 平台费用 + API 等价；按日期升序，任何输入顺序都产出稳定结果。
// API 等价只在当天有模型明细时填写，留空表示无明细（不是 0 元）。
enum UsageCSVExport {
    private static let codingColumns: [(source: HistorySource, title: String)] = [
        (.claude, "Claude"), (.codex, "Codex"), (.kimi, "Kimi"),
        (.opencode, "OpenCode"), (.gemini, "Gemini"), (.copilot, "Copilot"),
        (.qwen, "Qwen Code"), (.cursor, "Cursor"),
    ]

    static func makeCSV(
        _ days: [HistoryStore.DayPoint],
        apiValueByDate: [String: Double] = [:]
    ) -> String {
        var lines = [[String]]()
        lines.append(["日期"]
            + codingColumns.map(\.title)
            + ["Coding 合计", "DeepSeek 平台", "平台费用(USD)", "API 等价(USD)"])
        for day in days.sorted(by: { $0.date < $1.date }) {
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
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
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
