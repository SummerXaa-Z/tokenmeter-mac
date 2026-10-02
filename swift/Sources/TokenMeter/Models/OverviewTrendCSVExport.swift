import Foundation

// 总览趋势卡导出 CSV：逐桶一行（小时档今日逐时、日档逐日、周档自然周、
// 月档自然月），来源分列 + 合计，列与图例 chips / 悬停说明行同口径——
// 图例点暗隐藏的来源不导（与所见一致），金额列与悬停金额同口径。
// 数字保持原始整数；API 等价无金额留空（不是 0 元），小时档无逐时金额
// 不设金额列（今日合计金额写进口径行）。
enum OverviewTrendCSVExport {
    static func makeCSV(
        trend: [OverviewSnapshot.TrendPoint],
        granularity: UsageTrendGranularity,
        rangeTitle: String,
        apiValueByTrendBucket: [String: [HistorySource: Double]] = [:],
        todayKey: String = DateUtil.today()
    ) -> String {
        // 来源列序：范围内合计降序，与图例 chips 同序
        let sources = TrendSeriesFilter.seriesTotals(trend).map(\.name)
        let isHour = granularity == .hour
        let buckets = Self.buckets(from: trend, isHour: isHour)
        let included = Set(sources)

        var lines: [[String]] = []
        lines.append(headerRow(sources: sources, isHour: isHour))
        for bucket in buckets {
            lines.append(dataRow(
                bucket: bucket, sources: sources, isHour: isHour,
                apiValueByTrendBucket: apiValueByTrendBucket, included: included))
        }
        if !buckets.isEmpty {
            lines.append(totalRow(
                buckets: buckets, sources: sources, isHour: isHour))
        }
        appendNotes(
            to: &lines, granularity: granularity, rangeTitle: rangeTitle,
            isHour: isHour, included: included,
            apiValueByTrendBucket: apiValueByTrendBucket, todayKey: todayKey)
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// 分桶：小时按钟点升序（0-23 全钟点照列），其余按日期键升序
    private static func buckets(
        from trend: [OverviewSnapshot.TrendPoint], isHour: Bool
    ) -> [(key: String, points: [OverviewSnapshot.TrendPoint])] {
        var buckets: [(key: String, sort: Int, points: [OverviewSnapshot.TrendPoint])] = []
        var indexByKey: [String: Int] = [:]
        for point in trend {
            let key = isHour ? String(point.hour ?? 0) : point.date
            if let index = indexByKey[key] {
                buckets[index].points.append(point)
            } else {
                indexByKey[key] = buckets.count
                buckets.append((key: key, sort: isHour ? (point.hour ?? 0) : 0, points: [point]))
            }
        }
        buckets.sort { isHour ? $0.sort < $1.sort : $0.key < $1.key }
        return buckets.map { (key: $0.key, points: $0.points) }
    }

    private static func headerRow(sources: [String], isHour: Bool) -> [String] {
        var cells = [isHour ? "小时" : "日期"] + sources + ["合计"]
        if !isHour { cells.append("API 等价(USD)") }
        return cells
    }

    private static func dataRow(
        bucket: (key: String, points: [OverviewSnapshot.TrendPoint]),
        sources: [String],
        isHour: Bool,
        apiValueByTrendBucket: [String: [HistorySource: Double]],
        included: Set<String>
    ) -> [String] {
        var bySource: [String: Int] = [:]
        for point in bucket.points {
            bySource[point.source.overviewChartName] =
                (bySource[point.source.overviewChartName] ?? 0) + point.tokens
        }
        var cells = [bucket.key]
        for name in sources {
            cells.append(String(bySource[name] ?? 0))
        }
        cells.append(String(bucket.points.reduce(0) { $0 + $1.tokens }))
        if !isHour {
            // 金额与悬停同口径：桶内逐源合计，只计导出包含的来源；
            // 小时档无逐时金额，不设该列
            var usd: Double?
            if let bySourceAmount = apiValueByTrendBucket[bucket.key] {
                let sum = bySourceAmount
                    .filter { included.contains($0.key.overviewChartName) }
                    .reduce(0.0) { $0 + $1.value }
                usd = sum > 0 ? sum : nil
            }
            cells.append(usd.map { String(format: "%.2f", $0) } ?? "")
        }
        return cells
    }

    private static func totalRow(
        buckets: [(key: String, points: [OverviewSnapshot.TrendPoint])],
        sources: [String],
        isHour: Bool
    ) -> [String] {
        var bySource: [String: Int] = [:]
        var total = 0
        for bucket in buckets {
            for point in bucket.points {
                bySource[point.source.overviewChartName] =
                    (bySource[point.source.overviewChartName] ?? 0) + point.tokens
                total += point.tokens
            }
        }
        var cells = ["合计"]
        for name in sources {
            cells.append(String(bySource[name] ?? 0))
        }
        cells.append(String(total))
        if !isHour {
            // 金额合计在视图层不便逐桶回传,这里恒留空,由口径行说明金额口径
            cells.append("")
        }
        return cells
    }

    private static func appendNotes(
        to lines: inout [[String]],
        granularity: UsageTrendGranularity,
        rangeTitle: String,
        isHour: Bool,
        included: Set<String>,
        apiValueByTrendBucket: [String: [HistorySource: Double]],
        todayKey: String
    ) {
        var notes: [String] = [
            "口径",
            "\(rangeTitle) · \(granularity.rawValue)（与趋势图同桶）",
        ]
        switch granularity {
        case .hour:
            notes.append("小时 = 今日逐时（0-23 全钟点照列，无用量为 0）")
        case .day:
            notes.append("逐日一行（日期键为自然日）")
        case .week:
            notes.append("周桶锚定周一（日期键为该周周一）")
        case .month:
            notes.append("月桶为自然月（日期键为该月 1 日）")
        }
        notes.append("来源列按范围内合计降序（与图例一致）；图例点暗隐藏的来源不导出")
        if isHour {
            // 小时档金额只有日粒度：今日合计写进口径行，不在逐时行里冒充
            let todaySum = apiValueByTrendBucket.values.reduce(0.0) { sum, bySource in
                sum + bySource
                    .filter { included.contains($0.key.overviewChartName) }
                    .reduce(0.0) { $0 + $1.value }
            }
            notes.append(todaySum > 0
                ? String(format: "小时档无逐时金额；今日 API 等价合计 %.2f USD", todaySum)
                : "小时档无逐时金额")
        } else {
            notes.append("API 等价(USD) 与悬停金额同口径（按当日生效价重算），无金额留空；合计行金额留空")
        }
        notes.append("Token 为原始整数")
        notes.append("导出于 \(todayKey)")
        for note in notes {
            lines.append([ModelRankingCSVExport.escaped(note)])
        }
    }

    static func suggestedFilename(
        range: UsageHistoryRange,
        todayKey: String = DateUtil.today()
    ) -> String {
        let slug: String
        switch range {
        case .day: slug = "1d"
        case .week: slug = "7d"
        case .month: slug = "30d"
        case .all: slug = "all"
        }
        return "TokenMeter-trend-\(slug)-\(todayKey).csv"
    }
}
