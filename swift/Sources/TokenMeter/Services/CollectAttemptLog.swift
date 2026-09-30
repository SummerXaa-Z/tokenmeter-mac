import Foundation

// 各本地来源最近一次采集的成败、耗时与完成时间。
// AppState 的 loadX 每轮采集结束记一笔(同源覆盖,只留最近一次);持久化为
// UserDefaults 里的小 JSON,重启后健康面板仍能看到上一次的结果。
// 失败摘要只存采集器自述的错误文案(与来源页展示同源),压成单行并截断,
// 不落任何会话内容、路径之外的文件信息或凭据。
enum CollectAttemptLog {
    struct Attempt: Codable, Equatable {
        let source: HistorySource
        let startedAt: Date
        let finishedAt: Date
        let failure: String?   // nil = 成功

        var succeeded: Bool { failure == nil }

        var durationMS: Int {
            max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000))
        }
    }

    private static let lock = NSLock()
    private static let key = "tokenmeter.collectAttempts.v1"
    private static var cache: [HistorySource: Attempt]?
    private static var defaults: UserDefaults = .standard

    /// 测试/工具注入独立 defaults;同时清空内存缓存,避免读到上一个 suite 的记录。
    static func useDefaults(_ value: UserDefaults) {
        lock.lock(); defer { lock.unlock() }
        defaults = value
        cache = nil
    }

    static func record(_ attempt: Attempt, persist: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        var table = loadCache()
        table[attempt.source] = attempt
        cache = table
        guard persist else { return }
        if let data = try? JSONEncoder().encode(Array(table.values)) {
            defaults.set(data, forKey: key)
        }
    }

    static func attempt(for source: HistorySource) -> Attempt? {
        lock.lock(); defer { lock.unlock() }
        return loadCache()[source]
    }

    /// 渲染夹具专用:只写内存,绝不落真实 UserDefaults。
    static func seedForPreview(_ attempt: Attempt) {
        record(attempt, persist: false)
    }

    private static func loadCache() -> [HistorySource: Attempt] {
        if let cache { return cache }
        var table: [HistorySource: Attempt] = [:]
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([Attempt].self, from: data)
        {
            for attempt in list { table[attempt.source] = attempt }
        }
        cache = table
        return table
    }

    /// 耗时文案:"0.8s"、"12s"、"2m05s"、"1h03m"。
    static func durationText(_ ms: Int) -> String {
        let seconds = Double(max(0, ms)) / 1000
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        if minutes < 60 { return String(format: "%dm%02ds", minutes, total % 60) }
        return String(format: "%dh%02dm", minutes / 60, minutes % 60)
    }

    /// 失败摘要:压成单行,超过 140 字符截断加省略号。
    static func failureSummary(_ message: String) -> String {
        let oneLine = message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard oneLine.count > 140 else { return oneLine }
        return String(oneLine.prefix(139)) + "…"
    }
}
