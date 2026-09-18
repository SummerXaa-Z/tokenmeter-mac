import Foundation

// 数据格式化，对应原版 main.tsx 顶部的 fmt* 工具函数
enum Fmt {
    // 千分位整数：2609 -> "2,609"。formatter 只在首用时配置一次。
    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static func int(_ n: Int) -> String {
        intFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    // 百分比：0.87 -> "87%"（视图不要再内联 String(format: "%.0f%%")）
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    // 美元金额：1.5 -> "$1.50"；整数额度可传 fractionDigits: 0
    static func usd(_ value: Double, fractionDigits: Int = 2) -> String {
        String(format: "$%.\(fractionDigits)f", value)
    }

    // 距目标时刻的中文倒计时："3 天后" / "5 小时后" / "12 分钟后"。
    // 已过期返回 elapsedText（默认"已"，调用方拼接"已重置"等完整句）。
    static func countdown(to date: Date, elapsedText: String = "已") -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return elapsedText }
        let hours = Int(interval) / 3600
        if hours >= 24 { return "\(hours / 24) 天后" }
        if hours >= 1 { return "\(hours) 小时后" }
        return "\(max(Int(interval) / 60, 1)) 分钟后"
    }

    // Token 缩写：1200000000 -> "1.2B"、380000000 -> "380M"、
    // 1000000 -> "1M"、2609 -> "2.6K"。尾随 .0 一律省去，让图表轴刻度
    // （25M/50M/75M/100M）与正文数值保持同一格式。M 四舍五入到 1000 时
    // 提升为 B，避免在窄卡片里出现“1000M”这种难读边界值。
    static func tokensShort(_ n: Int) -> String {
        let d = Double(n)
        // 先格式化数字再去掉尾随 .0，最后拼单位——否则 ".0" 匹配不到
        func short(_ value: Double, _ unit: String) -> String {
            let s = String(format: "%.1f", value)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if (d / 1e6).rounded() >= 1_000 {
            if d >= 1e11 { return String(format: "%.0fB", d / 1e9) }
            return short(d / 1e9, "B")
        }
        if d >= 1e8 { return String(format: "%.0fM", d / 1e6) }
        if d >= 1e6 { return short(d / 1e6, "M") }
        if d >= 1e3 { return short(d / 1e3, "K") }
        return String(n)
    }

    // 金额：¥1.45（货币符号外部决定）
    static func money(_ n: Double, symbol: String = "¥") -> String {
        symbol + String(format: "%.2f", n)
    }

    // "2026-06-11" -> "6/11"
    static func mmdd(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              let m = Int(parts[1]), let d = Int(parts[2]) else { return date }
        return "\(m)/\(d)"
    }

    // Date -> "6/11"（formatter 静态复用，视图不再各自 new DateFormatter）
    private static let mmddDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    static func mmdd(_ date: Date) -> String {
        mmddDateFormatter.string(from: date)
    }

    // "2026-06-11" -> "2026/6/11"
    static func ymd(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return date
        }
        return "\(y)/\(m)/\(d)"
    }

    // "2026-06-11" -> "2026/6"
    static func ym(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]) else { return date }
        return "\(y)/\(m)"
    }
}

// 日期工具，对应 todayStr / dateKey / addDays / recentUsageDays
enum DateUtil {
    static func key(_ date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func today() -> String { key(Date()) }

    static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        guard let date = Calendar.current.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        ), DateUtil.key(date) == key else { return nil }
        return date
    }

    static func addDays(_ date: Date, _ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: date) ?? date
    }

    // 取最近 count 天，缺失日期补零，对应 recentUsageDays
    static func recentDays(_ days: [UsageDay], count: Int = 7) -> [UsageDay] {
        let todayStr = today()
        var source: [String: UsageDay] = [:]
        for d in days where d.date <= todayStr { source[d.date] = d }
        let now = Date()
        return (0..<count).map { idx -> UsageDay in
            let date = key(addDays(now, idx - count + 1))
            return source[date] ?? .empty(date)
        }
    }

    // 上一个月，对应 previousMonth
    static func previousMonth(_ date: Date) -> (month: Int, year: Int) {
        let cal = Calendar.current
        let comp = cal.dateComponents([.year, .month], from: date)
        let first = cal.date(from: DateComponents(year: comp.year, month: comp.month, day: 1)) ?? date
        let prev = cal.date(byAdding: .month, value: -1, to: first) ?? date
        let c = cal.dateComponents([.year, .month], from: prev)
        return (c.month ?? 1, c.year ?? 2026)
    }
}
