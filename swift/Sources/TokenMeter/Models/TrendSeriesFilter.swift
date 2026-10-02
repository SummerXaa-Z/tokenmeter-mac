import Foundation

// 总览趋势图的系列筛选:chips 点选隐藏来源,只影响图表与悬停说明行,
// 不改趋势数据本身(合计文案仍由 OverviewSnapshot 全量口径给出)。
enum TrendSeriesFilter {
    typealias TrendPoint = OverviewSnapshot.TrendPoint

    /// 范围内各来源合计,按值降序、剔除零值——chips 的展示顺序。
    static func seriesTotals(_ points: [TrendPoint]) -> [(name: String, total: Int)] {
        var totals: [String: Int] = [:]
        for point in points {
            totals[point.source.overviewChartName, default: 0] += point.tokens
        }
        return totals
            .filter { $0.value > 0 }
            .map { (name: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    static func visible(_ points: [TrendPoint], hidden: Set<String>) -> [TrendPoint] {
        guard !hidden.isEmpty else { return points }
        return points.filter { !hidden.contains(pointName($0)) }
    }

    /// 趋势是否整窗无数据:无桶,或全部桶为零(日/周/月档的时间轴会补零,
    /// 只看 isEmpty 走不到空态)。按全量口径判——图例点暗隐藏不算空。
    static func isAllZero(_ points: [TrendPoint]) -> Bool {
        points.isEmpty || points.allSatisfy { $0.tokens == 0 }
    }

    static func pointName(_ point: TrendPoint) -> String {
        point.source.overviewChartName
    }
}

// 图例 chip 悬停说明行的装配：范围内该来源的合计 Token、榜内排名、
// 占比与 API 等价文本——多来源对比不必点开图例逐个排，悬停即读数。
// name 不在 totals 里(悬停态理论不发生，防呆)返回 nil。
enum OverviewSeriesHover {
    static func summary(
        name: String,
        seriesTotals: [(name: String, total: Int)],
        rangeTotal: Int,
        amount: Double?
    ) -> (label: String, total: Int, amountText: String?)? {
        guard let index = seriesTotals.firstIndex(where: { $0.name == name }) else {
            return nil
        }
        let entry = seriesTotals[index]
        // totals 已按合计降序(chips 的展示顺序),名次即位置 + 1
        var label = "\(name) · 范围内合计 · 第 \(index + 1) 名"
        if rangeTotal > 0 {
            label += " · 占 \(Int((Double(entry.total) / Double(rangeTotal) * 100).rounded()))%"
        }
        let amountText: String?
        if let amount, amount > 0 {
            amountText = Fmt.usd(amount)
        } else {
            amountText = nil
        }
        return (label: label, total: entry.total, amountText: amountText)
    }
}
