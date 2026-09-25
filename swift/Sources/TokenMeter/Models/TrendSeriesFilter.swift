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
        return points.filter { !hidden.contains($0.source.overviewChartName) }
    }
}
