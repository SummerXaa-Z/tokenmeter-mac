import Foundation

// 数据格式化，对应原版 main.tsx 顶部的 fmt* 工具函数
enum Fmt {
    // 千分位整数：2609 -> "2,609"
    static func int(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    // Token 缩写：380000000 -> "380M"、1000000 -> "1.0M"、2609 -> "2.6K"
    static func tokensShort(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e8 { return String(format: "%.0fM", d / 1e6) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
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
}

// 日期工具，对应 todayStr / dateKey / addDays / recentUsageDays
enum DateUtil {
    static func key(_ date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func today() -> String { key(Date()) }

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
