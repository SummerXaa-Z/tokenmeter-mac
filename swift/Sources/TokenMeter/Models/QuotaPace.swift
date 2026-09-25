import Foundation

// 额度节奏：把"剩余 % + 窗口起止"换算成"按当前速度重置前会不会用完"。
// 线性外推——已用比例 ÷ 已过时间比例 = 节奏倍率；倍率 > 1 即按当前速度会
// 先于重置耗尽。窗口刚开始（已过 < 5%）时样本太少、外推会被一两次请求放大，
// 不给结论；已经用尽的窗口由进度条自己说明，也不再预测。
struct QuotaPace: Equatable {
    enum Status: Equatable {
        case ahead(exhaustAt: Date)   // 按当前速度会在重置前用完
        case sustainable              // 撑得到重置
    }

    let elapsedFraction: Double              // 0...1，窗口时间已过比例
    let usedFraction: Double                 // 0...1
    let projectedRemainingAtReset: Double    // 0...1，ahead 时为 0
    let status: Status

    static let minimumElapsedFraction = 0.05

    // 进度条上的匀速参照刻度：按均匀消耗，此刻应剩的比例
    var evenPaceRemaining: Double { 1 - elapsedFraction }

    static func compute(
        remainingPercent: Double?,
        windowStart: Date?,
        resetAt: Date?,
        now: Date = Date()
    ) -> QuotaPace? {
        guard let remainingPercent, remainingPercent.isFinite,
              let windowStart, let resetAt, resetAt > windowStart, now < resetAt
        else { return nil }
        let remaining = min(max(remainingPercent, 0), 100) / 100
        guard remaining > 0 else { return nil }
        let total = resetAt.timeIntervalSince(windowStart)
        let elapsed = now.timeIntervalSince(windowStart)
        let elapsedFraction = elapsed / total
        guard elapsedFraction >= minimumElapsedFraction, elapsedFraction <= 1 else { return nil }
        let used = 1 - remaining
        // 已用比例超过已过时间比例 ⇔ 线性外推的耗尽时刻早于重置
        let ratio = used / elapsedFraction
        let status: Status
        let projected: Double
        if ratio > 1 {
            let exhaustAt = now.addingTimeInterval(remaining / (used / elapsed))
            status = .ahead(exhaustAt: exhaustAt)
            projected = 0
        } else {
            status = .sustainable
            projected = 1 - ratio
        }
        return QuotaPace(
            elapsedFraction: elapsedFraction,
            usedFraction: used,
            projectedRemainingAtReset: projected,
            status: status
        )
    }

    var isAhead: Bool {
        if case .ahead = status { return true }
        return false
    }

    // 一行结论：会提前用完给出预计耗尽时刻，否则给出预计重置时的余量
    func summary(now: Date = Date()) -> String {
        switch status {
        case .ahead(let exhaustAt):
            return "按当前速度\(Self.countdown(from: now, to: exhaustAt))用完，早于重置"
        case .sustainable:
            return "预计重置时剩 \(Self.percent(projectedRemainingAtReset))"
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func countdown(from now: Date, to date: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "即将" }
        let hours = Int(interval) / 3600
        if hours >= 24 { return "约 \(hours / 24) 天后" }
        if hours >= 1 { return "约 \(hours) 小时后" }
        return "约 \(max(Int(interval) / 60, 1)) 分钟后"
    }

    // 窗口起点：固定时长窗口直接回推；月窗按日历月回推（28–31 天不等）
    static func windowStart(resetAt: Date?, seconds: TimeInterval?) -> Date? {
        guard let resetAt, let seconds, seconds > 0 else { return nil }
        return resetAt.addingTimeInterval(-seconds)
    }

    static func monthWindowStart(resetAt: Date?, calendar: Calendar = .current) -> Date? {
        guard let resetAt else { return nil }
        return calendar.date(byAdding: .month, value: -1, to: resetAt)
    }
}

// 额度提前耗尽预测提醒：只看 ≥1 天的长窗口（5 小时窗波动大、很快重置，
// 提醒价值低还吵），且窗口至少过了 20%、预计耗尽时刻比重置早 6 小时以上，
// 避免窗口初期或临近重置时的误报。key 带窗口重置时刻：节奏在 1 附近来回
// 摆动时同一窗口也只提醒一次，窗口滚动后自然换新 key。
enum QuotaPaceAlert {
    struct Item: Equatable {
        let key: String
        let crossed: Bool
        let title: String
        let body: String
    }

    static let minimumWindow: TimeInterval = 86_400
    static let minimumElapsedFraction = 0.2
    static let minimumLead: TimeInterval = 6 * 3600

    static func items(_ snapshot: SubscriptionQuotaSnapshot, now: Date = Date()) -> [Item] {
        var result: [Item] = []
        for group in snapshot.groups {
            for period in group.periods {
                guard let start = period.windowStart, let reset = period.resetAt,
                      reset.timeIntervalSince(start) >= minimumWindow
                else { continue }
                let pace = QuotaPace.compute(
                    remainingPercent: period.remainingPercent,
                    windowStart: start, resetAt: reset, now: now)
                var crossed = false
                var body = ""
                if let pace, pace.elapsedFraction >= minimumElapsedFraction,
                   case .ahead(let exhaustAt) = pace.status,
                   reset.timeIntervalSince(exhaustAt) >= minimumLead {
                    crossed = true
                    body = "已用 \(QuotaPace.percent(pace.usedFraction))，窗口时间才过 "
                        + "\(QuotaPace.percent(pace.elapsedFraction))；按当前速度约 "
                        + "\(stamp(exhaustAt)) 耗尽，早于 \(stamp(reset)) 重置"
                }
                result.append(Item(
                    key: "quota.pace.\(period.id)@\(Int(reset.timeIntervalSince1970 / 3600))",
                    crossed: crossed,
                    title: "\(group.title) \(period.label)额度可能提前用完",
                    body: body
                ))
            }
        }
        return result
    }

    private static func stamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}

// DeepSeek 余额可用天数：按近 7 个完整日（不含今天，今天还没过完）的日均
// 平台费用估算。记录不足 7 天时分母只取有记录以来的天数，避免新装用户被
// 补零天拉低日均、把可用天数估得虚高；无消费时不估算。
enum BalanceRunway {
    struct Estimate: Equatable {
        let dailyAverage: Double
        let days: Double
        let sampleDays: Int
    }

    static func estimate(
        balance: Double,
        history: [HistoryStore.DayPoint],
        today: String = DateUtil.today()
    ) -> Estimate? {
        guard balance.isFinite, balance > 0 else { return nil }
        let complete = history
            .filter { $0.date < today }
            .sorted { $0.date < $1.date }
        guard let firstRecorded = complete.firstIndex(where: { $0.cost(for: .deepseek) > 0 })
        else { return nil }
        let window = complete[firstRecorded...].suffix(7)
        let total = window.reduce(0) { $0 + max($1.cost(for: .deepseek), 0) }
        guard total > 0 else { return nil }
        let average = total / Double(window.count)
        return Estimate(dailyAverage: average, days: balance / average, sampleDays: window.count)
    }

    // 平台费用按人民币记账；美元余额无法同口径换算，不估算
    static func estimate(_ balance: Balance, history: [HistoryStore.DayPoint]) -> Estimate? {
        guard balance.currency != "USD", let value = Double(balance.totalBalance) else { return nil }
        return estimate(balance: value, history: history)
    }

    static func daysText(_ days: Double) -> String {
        if days >= 365 { return "一年以上" }
        if days < 1 { return "不到 1 天" }
        return "\(Int(days.rounded(.down))) 天"
    }
}
