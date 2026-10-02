import Foundation

// DeepSeek 模型详情页 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 行序即页内「近 7 天 Token」趋势图——逐日一行（滚动窗口含今天、补零日
// 照列）。Token 为平台返回的当日该模型合计原始整数；消费为平台返回费用
// （人民币），与 API 等价估算口径不同，口径行里点名。转义复用模型榜导出。
enum DeepSeekModelCSVExport {
    struct Row {
        let date: String   // yyyy-MM-dd
        let tokens: Int    // 当日该模型合计；0 是真实零
    }

    static func makeCSV(
        model: UsageModelSummary,
        rows: [Row],
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current
    ) -> String {
        var lines = [[String]]()
        lines.append(["日期", "星期", "Token"])
        for row in rows {
            let weekday = DateUtil.date(from: row.date)
                .map { calendar.component(.weekday, from: $0) }
            lines.append([
                row.date,
                HeatmapCSVExport.weekdayLabel(weekday),
                String(row.tokens),
            ])
        }
        lines.append([
            "口径",
            escaped("DeepSeek \(model.name) · 近 7 天"),
            escaped("逐日一行（滚动窗口含今天，无用量日照列 0）"),
            "Token为平台返回的当日该模型合计",
            escaped(
                "汇总：总 Token \(model.totalTokens) · " +
                "请求数 \(model.requestCount) · " +
                "消费 \(Fmt.money(model.cost))"),
            escaped(
                "Token 构成（当月）：缓存命中 \(model.cacheHitTokens) / " +
                "未命中 \(model.cacheMissTokens) / " +
                "输出 \(model.responseTokens)"),
            "消费为平台返回费用(人民币)，非 API 等价估算",
            "导出于 \(todayKey)",
        ])
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func suggestedFilename(modelKey: String) -> String {
        let display = modelKey == "flash" ? "V4 Flash" : "V4 Pro"
        let safe = ModelRankingCSVExport.sanitizedNameToken(display)
        let token = safe.isEmpty ? ModelRankingCSVExport.sanitizedNameToken(modelKey) : safe
        return "TokenMeter-deepseek-\(token.isEmpty ? "model" : token)-\(DateUtil.today()).csv"
    }

    private static func escaped(_ field: String) -> String {
        ModelRankingCSVExport.escaped(field)
    }
}
