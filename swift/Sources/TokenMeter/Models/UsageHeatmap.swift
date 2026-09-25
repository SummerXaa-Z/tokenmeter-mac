import Foundation

// 用量热力图:近 N 周每日 Coding 合计的日历格(周为列、周一到周日为行)。
// 深浅按非零日的分位数分四档——单一极值日不会把其余天压成最浅档。
enum UsageHeatmap {
    struct DayCell: Equatable {
        let date: String     // yyyy-MM-dd
        let weekday: Int     // Calendar weekday,1=周日 ... 7=周六
        let total: Int
        let level: Int       // 0=无用量,1...4 逐档加深
    }

    struct WeekColumn: Equatable {
        let weekOf: String       // 该周周一日期键
        let cells: [DayCell]     // 按 weekday 升序(首尾周可能不满)
        let monthLabel: String?  // 与前一列月份不同时给出,如 "9月"
    }

    // 周内节律:窗口内该星期几的日均。分母是出现次数而非有量天数——
    // 休整天计入分母,反映"这一天通常用多少"而不是"用的时候有多猛"。
    struct WeekdayStat: Equatable {
        let weekday: Int    // Calendar weekday,1=周日 ... 7=周六
        let average: Int
        let days: Int       // 窗口内该星期几出现的天数(含今天,不含未来)

        var label: String {
            ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
        }
    }

    static let windowWeeks = 13

    static func window(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        windowWeeks: Int = UsageHeatmap.windowWeeks,
        calendar: Calendar = .current
    ) -> [WeekColumn] {
        let allowed = Set(participants)
        var totals: [String: Int] = [:]
        for day in days {
            let total = day.bySource.reduce(0) { sum, entry in
                allowed.contains(entry.key) ? sum + max(entry.value, 0) : sum
            }
            guard total > 0 else { continue }
            totals[day.date, default: 0] += total
        }

        let start = calendar.date(
            byAdding: .day, value: -(windowWeeks * 7 - 1), to: calendar.startOfDay(for: today)
        ) ?? today
        let thresholds = quantileThresholds(Array(totals.values))

        var columns: [WeekColumn] = []
        var lastMonth = -1
        var currentWeekOf: String?
        var currentCells: [DayCell] = []
        var cursor = start
        while cursor <= today {
            let key = DateUtil.key(cursor)
            let total = totals[key] ?? 0
            let cell = DayCell(
                date: key,
                weekday: calendar.component(.weekday, from: cursor),
                total: total,
                level: level(for: total, thresholds: thresholds)
            )
            let weekOf = mondayKey(of: cursor, calendar: calendar)
            if weekOf != currentWeekOf {
                if let week = currentWeekOf {
                    columns.append(makeColumn(weekOf: week, cells: currentCells, lastMonth: &lastMonth))
                }
                currentWeekOf = weekOf
                currentCells = []
            }
            currentCells.append(cell)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        if let week = currentWeekOf {
            columns.append(makeColumn(weekOf: week, cells: currentCells, lastMonth: &lastMonth))
        }
        return columns
    }

    /// 当前连续使用天数,与个人画像同口径:从今天倒着数逐日累计;
    /// 今天尚未开始使用时容忍一次空白、从昨天起算,再遇空白即断。
    static func currentStreak(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let allowed = Set(participants)
        var used: Set<String> = []
        for day in days {
            let total = day.bySource.reduce(0) { sum, entry in
                allowed.contains(entry.key) ? sum + max(entry.value, 0) : sum
            }
            if total > 0 { used.insert(day.date) }
        }
        let start = calendar.startOfDay(for: today)
        var streak = 0
        for offset in 0...365 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start),
                  used.contains(DateUtil.key(date))
            else {
                if offset == 0 { continue }   // 今天还没开始用不算断
                break
            }
            streak += 1
        }
        return streak
    }

    /// 窗口内按星期几聚合的日均,按周一...周日排序返回 7 项。
    static func weekdayAverages(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        windowWeeks: Int = UsageHeatmap.windowWeeks,
        calendar: Calendar = .current
    ) -> [WeekdayStat] {
        let allowed = Set(participants)
        var totals: [String: Int] = [:]
        for day in days {
            let total = day.bySource.reduce(0) { sum, entry in
                allowed.contains(entry.key) ? sum + max(entry.value, 0) : sum
            }
            guard total > 0 else { continue }
            totals[day.date, default: 0] += total
        }

        var sums = [Int: Int]()
        var counts = [Int: Int]()
        let start = calendar.date(
            byAdding: .day, value: -(windowWeeks * 7 - 1), to: calendar.startOfDay(for: today)
        ) ?? today
        var cursor = start
        while cursor <= today {
            let weekday = calendar.component(.weekday, from: cursor)
            sums[weekday, default: 0] += totals[DateUtil.key(cursor)] ?? 0
            counts[weekday, default: 0] += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (2...8).map { slot in          // 2=周一 ... 7=周六, 8→周日(1)
            let weekday = slot == 8 ? 1 : slot
            let days = counts[weekday] ?? 0
            let sum = sums[weekday] ?? 0
            return WeekdayStat(weekday: weekday, average: days > 0 ? sum / days : 0, days: days)
        }
    }

    /// 非零日升序的 1/4、2/4、3/4 分位值;不足 4 天时仍给出可用阈值。
    private static func quantileThresholds(_ values: [Int]) -> [Int]? {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        return (1...3).map { q in
            sorted[min(sorted.count * q / 4, sorted.count - 1)]
        }
    }

    private static func level(for value: Int, thresholds: [Int]?) -> Int {
        guard value > 0, let t = thresholds else { return 0 }
        if value <= t[0] { return 1 }
        if value <= t[1] { return 2 }
        if value <= t[2] { return 3 }
        return 4
    }

    private static func mondayKey(of date: Date, calendar: Calendar) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        iso.firstWeekday = 2
        let monday = iso.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return DateUtil.key(monday)
    }

    private static func makeColumn(
        weekOf: String, cells: [DayCell], lastMonth: inout Int
    ) -> WeekColumn {
        var label: String?
        if let first = cells.first, let date = DateUtil.date(from: first.date) {
            let month = Calendar.current.component(.month, from: date)
            if month != lastMonth {
                label = "\(month)月"
                lastMonth = month
            }
        }
        return WeekColumn(weekOf: weekOf, cells: cells, monthLabel: label)
    }
}
