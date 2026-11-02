import Foundation

// 模型下钻页 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 行序即详情页当前档的趋势图——7/30 天档逐日一行（滚动窗口含今天、
// 补零日照列），90 天档按自然周聚合（周一为界、首尾周可能不足整周，
// 与页内趋势同口径）。Token 为该模型五类合计原始整数；API 等价与页内
// 同一条当日生效价管线，无金额留空——留空表示「没有这个口径的数字」。
// 末尾附「口径」行：来源+模型、档位与聚合语义、价格覆盖随文件自带。
// 转义复用模型榜导出。
enum CodingModelDetailCSVExport {
    struct Row {
        let bucket: String   // 日档=yyyy-MM-dd；90 天周档=该周周一
        let tokens: Int      // 桶内五类合计；0 是真实零
        let usd: Double?     // 桶内 API 等价；nil = 无计价金额
    }

    static func makeCSV(
        source: HistorySource,
        model: String,
        spanDays: Int,
        rows: [Row],
        coverage: Double?,
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current,
        scopeTitle: String? = nil,
        granularity: UsageTrendGranularity? = nil
    ) -> String {
        // 90 天档按自然周聚合，与页内趋势图同一分桶
        let selectedGranularity = granularity ?? (spanDays > 30 ? .week : .day)
        let weekly = selectedGranularity == .week
        let monthly = selectedGranularity == .month
        var lines = [[String]]()
        if weekly || monthly {
            lines.append([weekly ? "周(周一)" : "月(月首)", "Token", "API等价(USD)"])
        } else {
            lines.append(["日期", "星期", "Token", "API等价(USD)"])
        }
        for row in rows {
            let usd = row.usd.map { String(format: "%.2f", $0) } ?? ""
            if weekly || monthly {
                lines.append([row.bucket, String(row.tokens), usd])
            } else {
                let weekday = DateUtil.date(from: row.bucket)
                    .map { calendar.component(.weekday, from: $0) }
                lines.append([
                    row.bucket,
                    HeatmapCSVExport.weekdayLabel(weekday),
                    String(row.tokens),
                    usd,
                ])
            }
        }
        var footer = [
            "口径",
            escaped("\(source.overviewName) \(model) · \(scopeTitle ?? "近 \(spanDays) 天")"),
            escaped(monthly ? "按自然月聚合（月首为键，首尾月可能不足整月）"
                : weekly ? (scopeTitle == nil
                    ? "90 天档按自然周聚合（周一为界，首尾周可能不足整周）"
                    : "按自然周聚合（周一为界，首尾周可能不足整周）")
                : scopeTitle == nil ? "逐日一行（滚动窗口含今天，无用量日照列 0）"
                : "逐日一行（窗口含今天，无用量日照列 0）"),
            "Token为该模型五类合计",
            "API等价按用量当日生效价重算（缺价不计、无金额留空）；未知留空，已知零价与无用量为0，部分计价金额为下限",
        ]
        if let coverage, coverage < 0.999 {
            footer.append(escaped(
                "价格覆盖 \(Int((coverage * 100).rounded()))%，缺价或价格未生效的用量不计入金额"))
        }
        footer.append("导出于 \(todayKey)")
        lines.append(footer)
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func suggestedFilename(model: String) -> String {
        let safe = ModelRankingCSVExport.sanitizedNameToken(model)
        return "TokenMeter-model-\(safe.isEmpty ? "model" : safe)-\(DateUtil.today()).csv"
    }

    private static func escaped(_ field: String) -> String {
        ModelRankingCSVExport.escaped(field)
    }
}
