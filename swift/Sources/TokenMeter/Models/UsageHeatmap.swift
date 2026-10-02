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

    // 周视图格:把一周的日格折成一块。深浅按非零周合计的分位分档
    // (与日视图同一套分位逻辑,只是分位样本换成周合计)。
    struct WeekCell: Equatable {
        let weekOf: String       // 该周周一日期键
        let total: Int           // 周内合计
        let level: Int           // 0=无用量,1...4 逐档加深
        let usd: Double          // 周内 API 等价合计;0 = 无计价金额
        let monthLabel: String?
    }

    // 月视图格:一个自然月折成一块。深浅按非零月合计的分位分档
    // (与日/周视图同一套分位逻辑,只是分位样本换成月合计)。
    struct MonthCell: Equatable {
        let monthKey: String    // "yyyy-MM"
        let month: Int          // Calendar month,1...12
        let total: Int          // 月内合计(最新一页的当月为进行中)
        let level: Int          // 0=无用量,1...4 逐档加深
        let usd: Double         // 月内 API 等价合计;0 = 无计价金额
    }

    // 周内节律:窗口内该星期几的日均。分母是出现次数而非有量天数——
    // 休整天计入分母,反映"这一天通常用多少"而不是"用的时候有多猛";
    // activeDays 给出其中有量的天数,区分"常在但轻"与"偶尔爆发"。
    struct WeekdayStat: Equatable {
        let weekday: Int    // Calendar weekday,1=周日 ... 7=周六
        let average: Int
        let days: Int       // 窗口内该星期几出现的天数(含今天,不含未来)
        let activeDays: Int // 其中 Token > 0 的天数(0 ≤ activeDays ≤ days)

        var label: String {
            ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
        }
    }

    /// 周内节律悬停说明行的标签段:周几 + 活跃天数占出现次数的比例
    /// (如「周六 · 活跃 8/13 天」= 窗口内 13 个周六里 8 个有用量)。
    /// 出现次数为 0 时(理论上不发生)省略活跃段,只给周几。
    static func weekdayRhythmLabel(_ stat: WeekdayStat) -> String {
        guard stat.days > 0 else { return "周\(stat.label)" }
        return "周\(stat.label) · 活跃 \(stat.activeDays)/\(stat.days) 天"
    }

    static let windowWeeks = 13

    /// 按周翻页的窗口锚点(窗口终点):offset 0 = 今天;k = 整体前移 k 周
    /// (终点为今天往前第 k 周的同一天)。统一对齐到午夜,起点由终点推算,
    /// 任何偏移下窗口长度恒为 windowWeeks * 7 天。
    private static func anchorDate(
        today: Date, weekOffset: Int, calendar: Calendar
    ) -> Date {
        let shifted = weekOffset > 0
            ? calendar.date(byAdding: .day, value: -(weekOffset * 7), to: today) ?? today
            : today
        return calendar.startOfDay(for: shifted)
    }

    /// 还能往回翻几周:窗口终点不能早于最早有数据的那天(否则整窗空白),
    /// 再以 156 周(约三年)兜底防呆。
    static func maxWeekOffset(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let allowed = Set(participants)
        var earliest: Date?
        for day in days {
            let total = day.bySource.reduce(0) { sum, entry in
                allowed.contains(entry.key) ? sum + max(entry.value, 0) : sum
            }
            guard total > 0, let date = DateUtil.date(from: day.date) else { continue }
            if let seen = earliest, date >= seen { continue }
            earliest = date
        }
        guard let earliest else { return 0 }
        let daysBack = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: earliest),
            to: calendar.startOfDay(for: today)
        ).day ?? 0
        return min(max(0, daysBack / 7), 156)
    }

    /// 月视图窗口:calendar 自然月锚定。offset 0 = 含今天在内的最近
    /// monthCount 个自然月(当月进行中,窗口终点为今天);k = 整体前移
    /// k 个自然月(终点为该月最后一天),任何偏移下月数恒为 monthCount。
    static func monthWindow(
        today: Date,
        monthCount: Int,
        monthOffset: Int,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        guard monthCount > 0 else { return (today, today) }
        let anchorMonthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let endMonthStart = monthOffset > 0
            ? calendar.date(byAdding: .month, value: -monthOffset, to: anchorMonthStart)
                ?? anchorMonthStart
            : anchorMonthStart
        let start = calendar.date(
            byAdding: .month, value: -(monthCount - 1), to: endMonthStart) ?? endMonthStart
        let end: Date
        if monthOffset == 0 {
            end = calendar.startOfDay(for: today)
        } else if let nextMonth = calendar.date(byAdding: .month, value: 1, to: endMonthStart) {
            end = calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? endMonthStart
        } else {
            end = endMonthStart
        }
        return (start, end)
    }

    /// 月视图还能往回翻几个自然月:窗口终点月不能早于最早有数据的那个月,
    /// 再以 36 个月(约三年,与周视图 156 周同款上限)兜底防呆。
    static func maxMonthOffset(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let allowed = Set(participants)
        var earliest: Date?
        for day in days {
            let total = day.bySource.reduce(0) { sum, entry in
                allowed.contains(entry.key) ? sum + max(entry.value, 0) : sum
            }
            guard total > 0, let date = DateUtil.date(from: day.date) else { continue }
            if let seen = earliest, date >= seen { continue }
            earliest = date
        }
        guard let earliest else { return 0 }
        let months = calendar.dateComponents(
            [.month],
            from: calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest,
            to: calendar.dateInterval(of: .month, for: today)?.start ?? today
        ).month ?? 0
        return min(max(0, months), 36)
    }

    /// 窗口内逐日 API 等价美元（自然日键 → USD）：participants 的本地来源
    /// 合并到同一天，与总览/来源页同一价格口径（按用量当日生效的快照重算、
    /// 缺价模型不计入）。只读本机留存明细——热力图窗口远超实时采集的
    /// 7 天，混入实时会让最近一周与更早历史口径断层。金额为 0 的日子
    /// 不建条目（tooltip 自然不显示，不冒充 $0）。
    static func dailyAPIValues(
        participants: some Sequence<HistorySource>,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        today: Date = Date(),
        windowWeeks: Int = UsageHeatmap.windowWeeks,
        weekOffset: Int = 0,
        calendar: Calendar = .current
    ) -> [String: Double] {
        let anchor = anchorDate(today: today, weekOffset: weekOffset, calendar: calendar)
        let start = calendar.date(
            byAdding: .day, value: -(windowWeeks * 7 - 1), to: anchor) ?? anchor
        return dailyAPIValues(
            participants: participants, persisted: persisted,
            dateRange: (start, anchor), calendar: calendar)
    }

    /// 指定自然日区间（含两端）的逐日 API 等价：周窗口与月视图共用同一口径。
    static func dailyAPIValues(
        participants: some Sequence<HistorySource>,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        dateRange: (start: Date, end: Date),
        calendar: Calendar = .current
    ) -> [String: Double] {
        let allowed = Set(participants)
        guard allowed.contains(where: \.isCodingAgent) else { return [:] }
        var keys = Set<String>()
        var cursor = calendar.startOfDay(for: dateRange.start)
        let anchor = calendar.startOfDay(for: dateRange.end)
        while cursor <= anchor {
            keys.insert(DateUtil.key(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        var byDay: [String: [APICostSample]] = [:]
        for day in persisted
        where keys.contains(day.date) && ModelUsageHistoryStore.isDateKey(day.date) {
            var samples: [APICostSample] = []
            for source in day.bySource.keys.sorted(by: { $0.rawValue < $1.rawValue })
            where allowed.contains(source) {
                guard let detail = day.bySource[source] else { continue }
                for model in detail.models.keys.sorted() {
                    guard let tally = detail.models[model] else { continue }
                    samples.append(APICostSample(
                        model: model,
                        tokens: tally.breakdown,
                        usageDate: max(day.date, APIReferencePricingCatalog.firstObservedAt),
                        source: source))
                }
            }
            if !samples.isEmpty { byDay[day.date, default: []].append(contentsOf: samples) }
        }
        var result: [String: Double] = [:]
        for (date, samples) in byDay {
            let summary = APIReferenceCostSummary(
                samples: samples,
                estimator: APIReferencePricingCatalog.estimator,
                referenceDate: APIReferencePricingCatalog.observedAt,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
            if summary.total > 0 { result[date] = summary.total }
        }
        return result
    }

    /// 格子悬停说明：日期 · 合计 Token，有金额的日子追加美元金额。
    static func cellHelpText(date: String, total: Int, apiValue: Double?) -> String {
        var text = "\(Fmt.mmdd(date)) · \(Fmt.tokensShort(total))"
        if let apiValue, apiValue > 0 {
            text += " · \(Fmt.usd(apiValue))"
        }
        return text
    }

    /// 周格悬停说明：周（周一日期）· 周合计 Token，有金额时追加美元金额。
    static func weekHelpText(weekOf: String, total: Int, apiValue: Double?) -> String {
        var text = "\(Fmt.mmdd(weekOf))周 · \(Fmt.tokensShort(total))"
        if let apiValue, apiValue > 0 {
            text += " · \(Fmt.usd(apiValue))"
        }
        return text
    }

    /// 周视图：把日历格的周列折成逐周一块，周合计参与分位分档；
    /// apiValues 为 dailyAPIValues 的逐日金额，折成周内合计。
    static func weeklyCells(
        from columns: [WeekColumn],
        apiValues: [String: Double] = [:]
    ) -> [WeekCell] {
        let totals = columns.map { column in
            column.cells.reduce(0) { $0 + $1.total }
        }
        let thresholds = quantileThresholds(totals)
        return columns.indices.map { index in
            let column = columns[index]
            let usd = column.cells.reduce(0.0) { $0 + (apiValues[$1.date] ?? 0) }
            return WeekCell(
                weekOf: column.weekOf,
                total: totals[index],
                level: level(for: totals[index], thresholds: thresholds),
                usd: usd,
                monthLabel: column.monthLabel)
        }
    }

    /// 月格悬停说明：年月 · 月合计 Token，有金额时追加美元金额。
    /// 月视图动辄跨两年，悬停文案带年份消歧；进行中的当月（仅最近一页）
    /// 由调用方传 inProgress，明示"统计至今天"——月条按月合计分档着色，
    /// 没这半句容易把进行中的当月误读成用量骤降。进行中且给出 elapsedDays
    /// （本月已过的天数，含今天）时再附日均与已过天数，把"骤降"读法彻底
    /// 堵死：日均才是与完整月可比的口径。
    static func monthHelpText(
        monthKey: String,
        total: Int,
        apiValue: Double?,
        inProgress: Bool = false,
        elapsedDays: Int? = nil
    ) -> String {
        let parts = monthKey.split(separator: "-")
        let title: String
        if parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) {
            title = "\(year)年\(month)月"
        } else {
            title = monthKey
        }
        var text = title
        if inProgress { text += "（进行中，统计至今天）" }
        text += " · \(Fmt.tokensShort(total))"
        if inProgress, let elapsedDays, elapsedDays > 0 {
            text += " · 日均 \(Fmt.tokensShort(total / elapsedDays))（已 \(elapsedDays) 天）"
        }
        if let apiValue, apiValue > 0 {
            text += " · \(Fmt.usd(apiValue))"
        }
        return text
    }

    /// 月视图：把窗口内逐日合计按自然月归桶折成逐月一块，月合计参与
    /// 分位分档；apiValues 为 dailyAPIValues 的逐日金额，折成月内合计。
    /// 窗口外、非参与来源与平台账户不计。
    static func monthlyCells(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        apiValues: [String: Double] = [:],
        today: Date = Date(),
        monthCount: Int = 12,
        monthOffset: Int = 0,
        calendar: Calendar = .current
    ) -> [MonthCell] {
        let allowed = Set(participants)
        var totals: [String: Int] = [:]
        for day in days {
            let total = day.bySource.reduce(0) { sum, entry in
                allowed.contains(entry.key) ? sum + max(entry.value, 0) : sum
            }
            guard total > 0, day.date.count >= 7 else { continue }
            totals[String(day.date.prefix(7)), default: 0] += total
        }

        let range = monthWindow(
            today: today, monthCount: monthCount, monthOffset: monthOffset, calendar: calendar)
        let thresholds = quantileThresholds(Array(totals.values))

        var cells: [MonthCell] = []
        var seen = Set<String>()
        var cursor = range.start
        while cursor <= range.end {
            let key = String(DateUtil.key(cursor).prefix(7))
            if !seen.contains(key) {
                seen.insert(key)
                let total = totals[key] ?? 0
                let usd = apiValues.isEmpty
                    ? 0
                    : apiValues.reduce(0.0) { sum, entry in
                        entry.key.hasPrefix(key) ? sum + entry.value : sum
                    }
                cells.append(MonthCell(
                    monthKey: key,
                    month: calendar.component(.month, from: cursor),
                    total: total,
                    level: level(for: total, thresholds: thresholds),
                    usd: usd))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return cells
    }

    static func window(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        windowWeeks: Int = UsageHeatmap.windowWeeks,
        weekOffset: Int = 0,
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

        let anchor = anchorDate(today: today, weekOffset: weekOffset, calendar: calendar)
        let start = calendar.date(
            byAdding: .day, value: -(windowWeeks * 7 - 1), to: anchor) ?? anchor
        let thresholds = quantileThresholds(Array(totals.values))

        var columns: [WeekColumn] = []
        var lastMonth = -1
        var currentWeekOf: String?
        var currentCells: [DayCell] = []
        var cursor = start
        while cursor <= anchor {
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
        weekOffset: Int = 0,
        calendar: Calendar = .current
    ) -> [WeekdayStat] {
        let anchor = anchorDate(today: today, weekOffset: weekOffset, calendar: calendar)
        let start = calendar.date(
            byAdding: .day, value: -(windowWeeks * 7 - 1), to: anchor) ?? anchor
        return weekdayAverages(
            days, participants: participants, dateRange: (start, anchor), calendar: calendar)
    }

    /// 指定自然日区间（含两端、不含未来）的按星期几日均：周窗口与月视图共用。
    static func weekdayAverages(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        dateRange: (start: Date, end: Date),
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
        var activeCounts = [Int: Int]()
        var cursor = calendar.startOfDay(for: dateRange.start)
        let anchor = calendar.startOfDay(for: dateRange.end)
        while cursor <= anchor {
            let weekday = calendar.component(.weekday, from: cursor)
            let key = DateUtil.key(cursor)
            sums[weekday, default: 0] += totals[key] ?? 0
            counts[weekday, default: 0] += 1
            // totals 只收 Token > 0 的日子,在字典里即为有量
            if totals[key] != nil { activeCounts[weekday, default: 0] += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (2...8).map { slot in          // 2=周一 ... 7=周六, 8→周日(1)
            let weekday = slot == 8 ? 1 : slot
            let days = counts[weekday] ?? 0
            let sum = sums[weekday] ?? 0
            return WeekdayStat(
                weekday: weekday,
                average: days > 0 ? sum / days : 0,
                days: days,
                activeDays: min(activeCounts[weekday] ?? 0, days))
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

    static func mondayKey(of date: Date, calendar: Calendar) -> String {
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
