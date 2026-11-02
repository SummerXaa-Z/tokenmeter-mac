import Foundation

// 重置已经发生，只能说明旧窗口快照失效，不能据此推断新窗口剩余 100%。
// 缺重置时间的服务仍可展示观测值，但不能制造重置倒计时或节奏预测。
enum QuotaWindowFreshness {
    static func isExpired(resetAt: Date?, now: Date = Date()) -> Bool {
        guard let resetAt, resetAt.timeIntervalSince1970 > 0 else { return false }
        return resetAt <= now
    }

    static func remainingPercent(
        _ value: Double?, resetAt: Date?, now: Date = Date()
    ) -> Double? {
        guard !isExpired(resetAt: resetAt, now: now), let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    static func remainingPercent(_ window: CodexRateWindow, now: Date = Date()) -> Double? {
        // Codex 中 0 为缺失的重置时间，不能当作一个真实窗口继续评估告警。
        guard window.resetsAt.timeIntervalSince1970 > 0 else { return nil }
        return remainingPercent(100 - window.usedPercent, resetAt: window.resetsAt, now: now)
    }
}
