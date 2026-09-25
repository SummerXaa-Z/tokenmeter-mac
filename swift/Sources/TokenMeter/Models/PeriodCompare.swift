import Foundation

// 全来源周期环比:本周 vs 上周、近 7 天 vs 前 7 天、本月 vs 上月,
// 各 Coding 来源 Token 合计。日历周期为截至今天的部分周期,
// 近 7 天为滚动窗口——周初看日历周环比会因样本过短虚低,滚动口径更稳。
enum PeriodCompare {
    enum Period: Hashable {
        case week
        case rolling7
        case month

        var title: String {
            switch self {
            case .week: return "本周 vs 上周"
            case .rolling7: return "近 7 天 vs 前 7 天"
            case .month: return "本月 vs 上月"
            }
        }

        var footnote: String {
            switch self {
            case .week: return "日历周口径，本周截至今天"
            case .rolling7: return "滚动 7 天窗口，截至今天"
            case .month: return "日历月口径，本月截至今天"
            }
        }
    }

    struct Row: Equatable {
        let source: HistorySource
        let this: Int
        let last: Int
    }

    /// 本期与上期的统计区间,终点为排他边界。周用 ISO 周一(与趋势图周桶一致),
    /// 月用自然月 1 日;近 7 天为滚动窗口,两期各 7 天且不重叠。
    static func intervals(
        of period: Period,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> (this: DateInterval, last: DateInterval)? {
        if period == .rolling7 {
            let day = calendar.startOfDay(for: today)
            guard let lastStart = calendar.date(byAdding: .day, value: -13, to: day),
                  let thisStart = calendar.date(byAdding: .day, value: -6, to: day),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            return (DateInterval(start: thisStart, end: nextDay),
                    DateInterval(start: lastStart, end: thisStart))
        }
        let component: Calendar.Component = period == .month ? .month : .weekOfYear
        guard let thisInterval = calendar.dateInterval(of: component, for: today),
              let lastStart = calendar.date(
                  byAdding: component, value: -1, to: thisInterval.start),
              let lastInterval = calendar.dateInterval(of: component, for: lastStart)
        else { return nil }
        return (thisInterval, lastInterval)
    }

    static func bySource(
        _ days: [HistoryStore.DayPoint],
        period: Period,
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> (this: [HistorySource: Int], last: [HistorySource: Int]) {
        let allowed = Set(participants)
        guard !allowed.isEmpty,
              let intervals = intervals(of: period, today: today, calendar: calendar)
        else { return ([:], [:]) }

        var this: [HistorySource: Int] = [:]
        var last: [HistorySource: Int] = [:]
        for day in days {
            guard let date = DateUtil.date(from: day.date) else { continue }
            let inThis = intervals.this.contains(date)
            let inLast = intervals.last.contains(date)
            guard inThis || inLast else { continue }
            for (source, tokens) in day.bySource where allowed.contains(source) {
                if inThis {
                    this[source, default: 0] += tokens
                } else {
                    last[source, default: 0] += tokens
                }
            }
        }
        return (this, last)
    }

    /// 两期有量(任一期 > 0)的来源行,按两期较大值降序——合计行由视图另行计算。
    static func rows(
        this: [HistorySource: Int],
        last: [HistorySource: Int]
    ) -> [Row] {
        let sources = Set(this.keys).union(last.keys)
        return sources
            .map { Row(source: $0, this: this[$0] ?? 0, last: last[$0] ?? 0) }
            .filter { $0.this > 0 || $0.last > 0 }
            .sorted { max($0.this, $0.last) > max($1.this, $1.last) }
    }

    /// 环比变化百分比(上期为 0 时无基期,返回 nil 由视图显示 —)。
    static func change(this: Int, last: Int) -> Double? {
        guard last > 0 else { return nil }
        return (Double(this) - Double(last)) / Double(last) * 100
    }
}
