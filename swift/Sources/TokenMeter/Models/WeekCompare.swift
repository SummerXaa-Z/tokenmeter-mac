import Foundation

// 全来源日历周环比:本周 vs 上周各 Coding 来源 Token 合计。
// 与 Claude 页"周趋势"同语义——日历周口径,本周为截至今天的部分周。
enum WeekCompare {
    struct Row: Equatable {
        let source: HistorySource
        let this: Int
        let last: Int
    }

    static func bySource(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> (thisWeek: [HistorySource: Int], lastWeek: [HistorySource: Int]) {
        let allowed = Set(participants)
        guard !allowed.isEmpty else { return ([:], [:]) }
        guard let thisInterval = calendar.dateInterval(of: .weekOfYear, for: today),
              let lastStart = calendar.date(
                  byAdding: .weekOfYear, value: -1, to: thisInterval.start),
              let lastInterval = calendar.dateInterval(of: .weekOfYear, for: lastStart)
        else { return ([:], [:]) }

        var this: [HistorySource: Int] = [:]
        var last: [HistorySource: Int] = [:]
        for day in days {
            guard let date = DateUtil.date(from: day.date) else { continue }
            let inThisWeek = thisInterval.contains(date)
            let inLastWeek = lastInterval.contains(date)
            guard inThisWeek || inLastWeek else { continue }
            for (source, tokens) in day.bySource where allowed.contains(source) {
                if inThisWeek {
                    this[source, default: 0] += tokens
                } else {
                    last[source, default: 0] += tokens
                }
            }
        }
        return (this, last)
    }

    /// 两周有量(任一周 > 0)的来源行,按两周较大值降序——合计行由视图另行计算。
    static func rows(
        thisWeek: [HistorySource: Int],
        lastWeek: [HistorySource: Int]
    ) -> [Row] {
        let sources = Set(thisWeek.keys).union(lastWeek.keys)
        return sources
            .map { Row(source: $0, this: thisWeek[$0] ?? 0, last: lastWeek[$0] ?? 0) }
            .filter { $0.this > 0 || $0.last > 0 }
            .sorted { max($0.this, $0.last) > max($1.this, $1.last) }
    }

    /// 环比变化百分比(上周为 0 时无基期,返回 nil 由视图显示 —)。
    static func change(this: Int, last: Int) -> Double? {
        guard last > 0 else { return nil }
        return (Double(this) - Double(last)) / Double(last) * 100
    }
}
