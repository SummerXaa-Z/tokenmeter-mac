import Foundation

// 用量历史 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 列固定为 日期 + Coding 来源（不含 DeepSeek 平台）+ Coding 合计 + 平台 Token
// + 平台费用 + API 等价；按日期升序，任何输入顺序都产出稳定结果。
// API 等价只在当天有模型明细时填写，留空表示无明细（不是 0 元）。
// 可选按自然日窗口（近 N 天，滚动到今天）截取导出范围；末尾附「汇总」行
// （各列求和，与表头同列对齐）、「价格覆盖率」行（范围内已计价 tokens 占比，
// 说明 API 等价列的可靠程度）；填写了订阅月费时再附「订阅回本」行——
// 月费合计、按导出跨度折算的天数与订阅费、API 等价合计与回本倍数，
// 与总览同口径，且都只统计所选范围内的天——其后跟「订阅回本·周明细」
// 行：最近 13 个完整周逐周回本（与总览曲线同管线，不随导出范围截取）。
enum UsageCSVExport {
    enum ExportRange: Hashable {
        case all
        case lastDays(Int)
        /// 固定自然日窗口（含两端），如周报导出的「上周」或用户自选起止日期
        case window(start: String, end: String)
    }

    private static let codingColumns: [(source: HistorySource, title: String)] = [
        (.claude, "Claude"), (.codex, "Codex"), (.kimi, "Kimi"),
        (.opencode, "OpenCode"), (.gemini, "Gemini"), (.copilot, "Copilot"),
        (.qwen, "Qwen Code"), (.cursor, "Cursor"),
    ]

    /// 窗口起点日期键（含）；全部档与固定窗口档返回 nil。近 N 天=滚动窗口，
    /// 从今天往前数第 N 个自然日（含今天），与总览「近 7 天」同口径。
    static func windowStartDateKey(
        _ range: ExportRange,
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current
    ) -> String? {
        guard case let .lastDays(n) = range,
              let today = DateUtil.date(from: todayKey) else { return nil }
        let start = calendar.date(
            byAdding: .day, value: -(n - 1), to: calendar.startOfDay(for: today)) ?? today
        return DateUtil.key(start)
    }

    /// 周报同口径的「上周」窗口：今天往前 7 天所在的 ISO 周（周一到周日），
    /// 与 WeeklyDigest 的订阅折算窗口完全一致。
    static func lastWeekWindow(
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> ExportRange? {
        guard let lastWeek = calendar.date(byAdding: .day, value: -7, to: today)
        else { return nil }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        iso.firstWeekday = 2
        guard let week = iso.dateInterval(of: .weekOfYear, for: lastWeek),
              let weekEnd = calendar.date(byAdding: .day, value: 6, to: week.start)
        else { return nil }
        return .window(start: DateUtil.key(week.start), end: DateUtil.key(weekEnd))
    }

    static func makeCSV(
        _ days: [HistoryStore.DayPoint],
        apiValueByDate: [String: Double] = [:],
        modelHistory: [ModelUsageDay] = [],
        plans: [SubscriptionPlan] = [],
        range: ExportRange = .all,
        todayKey: String = DateUtil.today()
    ) -> String {
        var lines = [[String]]()
        lines.append(["日期"]
            + codingColumns.map(\.title)
            + ["Coding 合计", "DeepSeek 平台", "平台费用(USD)", "API 等价(USD)"])
        var sorted = days.sorted(by: { $0.date < $1.date })
        switch range {
        case .all:
            break
        case .lastDays:
            if let startKey = windowStartDateKey(range, todayKey: todayKey) {
                sorted = sorted.filter { $0.date >= startKey }
            }
        case .window(let start, let end):
            sorted = sorted.filter { $0.date >= start && $0.date <= end }
        }
        // 固定窗口档的折算边界用窗口本身（与周报同口径：整周自然日都摊），
        // 滚动/全部档沿用首末行日期
        let fixedBounds: (start: String, end: String)?
        if case let .window(start, end) = range { fixedBounds = (start, end) }
        else { fixedBounds = nil }
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
        if !sorted.isEmpty,
           let coverageRow = priceCoverageRow(
               modelHistory: modelHistory, range: range, todayKey: todayKey)
        {
            lines.append(coverageRow)
        }
        if let subscription = subscriptionSummary(
            sorted, fixedBounds: fixedBounds, apiValueByDate: apiValueByDate,
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
            lines.append(contentsOf: roiWeeklyRows(
                modelHistory: modelHistory, plans: plans, todayKey: todayKey))
        }
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// 「订阅回本·周明细」行：最近 13 个完整周逐周回本，与总览回本走势
    /// 曲线同一条管线（全部订阅合计、全部 Coding 来源），不随导出范围
    /// 截取——对账时与 App 内曲线逐点对得上。留存起点之前的周费用为
    /// 0、倍数留「—」；未填订阅或无按天明细时不输出任何行。
    private static func roiWeeklyRows(
        modelHistory: [ModelUsageDay],
        plans: [SubscriptionPlan],
        todayKey: String
    ) -> [[String]] {
        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(plans)
        guard monthlyFee > 0,
              let today = DateUtil.date(from: todayKey)
        else { return [] }
        return SubscriptionROICurve.weeklyPoints(
            participants: HistorySource.codingAgents,
            monthlyFeeUSD: monthlyFee,
            persisted: modelHistory,
            today: today
        ).map { point in
            [
                "订阅回本·周明细",
                "周(周一) \(point.weekOf)",
                String(format: "API 等价(USD) %.2f", point.apiValueUSD),
                String(format: "折算订阅费(USD) %.2f", point.feeUSD),
                point.multiple.map { String(format: "回本倍数 %.2f", $0) } ?? "回本倍数 —",
            ]
        }
    }

    /// 「价格覆盖率」行：范围内按天模型明细的已计价 tokens 占比（与逐日
    /// 金额同一套计价样本），对账时一眼看出「API 等价(USD)」列的可靠程度；
    /// 有缺价模型时点名。没有明细、没有 tokens 或明细全在窗口外时省略。
    private static func priceCoverageRow(
        modelHistory: [ModelUsageDay],
        range: ExportRange,
        todayKey: String
    ) -> [String]? {
        let startKey: String?
        switch range {
        case .all: startKey = nil
        case .lastDays: startKey = windowStartDateKey(range, todayKey: todayKey)
        case .window(let start, _): startKey = start
        }
        let endKey: String?
        if case let .window(_, end) = range { endKey = end } else { endKey = nil }

        let samples = modelHistory
            .filter { day in
                guard ModelUsageHistoryStore.isDateKey(day.date) else { return false }
                if let startKey, day.date < startKey { return false }
                if let endKey, day.date > endKey { return false }
                return true
            }
            .flatMap(samples(in:))
        guard !samples.isEmpty else { return nil }
        let summary = APIReferenceCostSummary(
            samples: samples,
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
        guard let coverage = summary.coverage else { return nil }
        var row = [
            "价格覆盖率",
            String(format: "覆盖率 %.1f%%", coverage * 100),
            "覆盖 tokens \(summary.matchedTokens) / \(summary.totalTokens)",
        ]
        if !summary.unpricedModels.isEmpty {
            row.append("缺价模型 " + summary.unpricedModels.joined(separator: "、"))
        }
        return row
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
    /// 没算进金额的天去摊订阅费（与总览/来源页同钳制）。API 等价合计
    /// 只统计导出范围内的天（与「汇总」行同口径）。固定窗口档
    /// （周报导出）的起点/终点取窗口边界而非首末行：与周报同按整周
    /// 自然日折算，周末空白日也计入分母。
    private static func subscriptionSummary(
        _ sorted: [HistoryStore.DayPoint],
        fixedBounds: (start: String, end: String)?,
        apiValueByDate: [String: Double],
        modelHistory: [ModelUsageDay],
        plans: [SubscriptionPlan]
    ) -> SubscriptionValueSummary? {
        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(plans)
        guard monthlyFee > 0,
              let exportStart = fixedBounds?.start ?? sorted.first?.date,
              let exportEnd = fixedBounds?.end ?? sorted.last?.date,
              let startDate = DateUtil.date(
                from: max(exportStart, detailCoverageStart(modelHistory) ?? exportStart)),
              let endDate = DateUtil.date(from: exportEnd),
              startDate <= endDate
        else { return nil }
        let days = Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        let apiTotal = sorted.compactMap { apiValueByDate[$0.date] }.reduce(0, +)
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

    // 一天里全部 Coding 来源的计价样本；首个快照之前的用量按首个快照计价。
    // 逐日金额（apiValueByDate）与范围覆盖率（priceCoverageRow）共用，
    // 保证两处口径永远一致。
    private static func samples(in day: ModelUsageDay) -> [APICostSample] {
        let pricingDate = max(day.date, APIReferencePricingCatalog.firstObservedAt)
        return HistorySource.codingAgents.flatMap { source in
            (day.bySource[source]?.models ?? [:]).map { model, tally in
                APICostSample(
                    model: model, tokens: tally.breakdown,
                    usageDate: pricingDate, source: source)
            }
        }
    }

    // 每天全部 Coding 来源的 API 等价金额（USD），与总览同一价格口径：
    // 首个快照之前的用量按首个快照计价，此后按用量当日生效价。
    static func apiValueByDate(_ modelHistory: [ModelUsageDay]) -> [String: Double] {
        var result: [String: Double] = [:]
        for day in modelHistory {
            let samples = samples(in: day)
            guard !samples.isEmpty else { continue }
            let summary = APIReferenceCostSummary(
                samples: samples,
                estimator: APIReferencePricingCatalog.estimator,
                referenceDate: max(day.date, APIReferencePricingCatalog.firstObservedAt),
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
            // 当天模型全部缺价时留空，不写成 0 元
            guard !summary.amounts.isEmpty else { continue }
            result[day.date] = summary.total
        }
        return result
    }

    static func suggestedFilename(range: ExportRange = .all) -> String {
        let suffix: String
        switch range {
        case .all: suffix = ""
        case .lastDays(let n): suffix = "-\(n)d"
        case .window(let start, let end):
            // "2026-09-14" → "0914";文件名直接标出窗口起止,跨按钮通用
            suffix = "-\(compact(start))-\(compact(end))"
        }
        return "TokenMeter-usage-\(DateUtil.today())\(suffix).csv"
    }

    private static func compact(_ dateKey: String) -> String {
        String(dateKey.suffix(5).replacingOccurrences(of: "-", with: ""))
    }

    /// 通知快捷动作的直落导出：不开保存面板，把周报同口径的上周 CSV
    /// 直接写入指定目录（App 侧传入「下载」文件夹）。数据装配与设置页
    /// 导出同一条管线；返回写成的文件名，窗口无法确定或写盘失败返回
    /// nil（调用方据此回执失败通知）。
    static func writeLastWeekCSV(
        directory: URL,
        days: [HistoryStore.DayPoint],
        apiValueByDate: [String: Double],
        modelHistory: [ModelUsageDay],
        plans: [SubscriptionPlan],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let range = lastWeekWindow(today: today, calendar: calendar) else {
            return nil
        }
        let csv = makeCSV(
            days,
            apiValueByDate: apiValueByDate,
            modelHistory: modelHistory,
            plans: plans,
            range: range)
        let url = directory.appendingPathComponent(suggestedFilename(range: range))
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url.lastPathComponent
        } catch {
            return nil
        }
    }
}
