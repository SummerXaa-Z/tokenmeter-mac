import Foundation

// A cached scan belongs to its recorded dates, not to the wall clock at render time.
// Hours belong to the final day of the scan; an old scan must not become today's chart.
extension ClaudeUsageResult {
    func day(on date: String) -> ClaudeDayUsage? { days.first { $0.date == date } }
    func dailyTokens(on date: String) -> Int? { day(on: date)?.totalTokens }
    func hourlyTokens(on date: String) -> [Int: Int]? {
        guard days.last?.date == date else { return nil }
        return todayHours.reduce(into: [:]) { $0[$1.hour, default: 0] += max($1.totalTokens, 0) }
    }
}
extension CodexUsageResult {
    func day(on date: String) -> CodexDayUsage? { days.first { $0.date == date } }
    func dailyTokens(on date: String) -> Int? { day(on: date)?.totalTokens }
    func hourlyTokens(on date: String) -> [Int: Int]? {
        guard days.last?.date == date else { return nil }
        return todayHours.reduce(into: [:]) { $0[$1.hour, default: 0] += max($1.totalTokens, 0) }
    }
}
extension KimiUsageResult {
    func day(on date: String) -> KimiDayUsage? { days.first { $0.date == date } }
    func dailyTokens(on date: String) -> Int? { day(on: date)?.totalTokens }
    func hourlyTokens(on date: String) -> [Int: Int]? {
        guard days.last?.date == date else { return nil }
        return todayHours.reduce(into: [:]) { $0[$1.hour, default: 0] += max($1.totalTokens, 0) }
    }
}
extension OpenCodeUsageResult {
    func day(on date: String) -> OpenCodeDayUsage? { days.first { $0.date == date } }
    func dailyTokens(on date: String) -> Int? { day(on: date)?.totalTokens }
    func hourlyTokens(on date: String) -> [Int: Int]? {
        guard days.last?.date == date else { return nil }
        return todayHours.reduce(into: [:]) { $0[$1.hour, default: 0] += max($1.totalTokens, 0) }
    }
}
extension GeminiUsageResult {
    func day(on date: String) -> GeminiDayUsage? { days.first { $0.date == date } }
    func dailyTokens(on date: String) -> Int? { day(on: date)?.totalTokens }
    func hourlyTokens(on date: String) -> [Int: Int]? {
        guard days.last?.date == date else { return nil }
        return todayHours.reduce(into: [:]) { $0[$1.hour, default: 0] += max($1.totalTokens, 0) }
    }
}
extension CopilotUsageResult {
    func day(on date: String) -> CopilotDayUsage? { days.first { $0.date == date } }
    func dailyTokens(on date: String) -> Int? { day(on: date)?.totalTokens }
}
extension QwenCodeUsageResult {
    func day(on date: String) -> QwenCodeDayUsage? { days.first { $0.date == date } }
    func dailyTokens(on date: String) -> Int? { day(on: date)?.totalTokens }
    func hourlyTokens(on date: String) -> [Int: Int]? {
        guard days.last?.date == date else { return nil }
        return todayHours.reduce(into: [:]) { $0[$1.hour, default: 0] += max($1.totalTokens, 0) }
    }
}
