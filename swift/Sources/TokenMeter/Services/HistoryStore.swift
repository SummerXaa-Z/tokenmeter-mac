import Foundation

// 用量历史留存：各源每次刷新把窗口内的按日用量 upsert 进一份 JSON，
// 落盘到 ~/Library/Application Support/TokenMeter/history.json。
//
// 为什么需要：Claude/Codex 只读最近 7 天、Cursor 只给当期聚合，App 一关
// 就只剩"当下窗口"，看不到更长期趋势。每天落盘后，过去的天固化下来，
// 趋势线能跨重启累积到 30 天以上。
//
// upsert 语义：窗口内的天用最新重算值覆盖（同一天多次刷新只留最后一次，
// 不累加），窗口外的旧天原样保留。这样既不重复计数，又不丢历史。
//
// 成本口径：仅 DeepSeek 的 days 带 cost；Claude/Codex 本地无单价，cost 存 nil。

enum HistorySource: String, CaseIterable, Codable {
    case deepseek, claude, codex, kimi, opencode, gemini, copilot, qwen, cursor

    // DeepSeek is an independent API/platform account, not a Coding Agent.
    // Keep the source in history for balance/cost views while excluding it from
    // every Coding Agent aggregation by construction.
    var isCodingAgent: Bool { self != .deepseek }

    static var codingAgents: [HistorySource] {
        allCases.filter(\.isCodingAgent)
    }
}

struct HistoryStore {
    // 单日单源记录
    struct DayEntry: Codable, Equatable {
        var totalTokens: Int
        var cost: Double?      // 仅 DeepSeek 有
    }

    // 磁盘结构：源 → 日期(YYYY-MM-DD) → 记录
    fileprivate typealias Table = [String: [String: DayEntry]]
    private static let storage = HistoryFileStore(fileURL:
        RuntimeEnvironment.applicationSupportDirectory.appendingPathComponent("history.json"))

    // 把某源窗口内的按日用量 upsert 进库。days: 日期 → (token, cost?)
    static func record(_ source: HistorySource, days: [(date: String, totalTokens: Int, cost: Double?)]) {
        // 仅兼容旧测试/调用；应用持久化管线使用抛错入口。
        _ = try? recordChecked(source, days: days)
    }

    @discardableResult
    static func recordChecked(
        _ source: HistorySource, days: [(date: String, totalTokens: Int, cost: Double?)]
    ) throws -> Bool {
        try storage.recordChecked(source, days: days)
    }

    // 用完整重扫得到的权威窗口修正已有记录。与 record 的区别是：0 代表
    // “这个日期已确认没有用量”，因此会删除同源旧值；但不会把 0 落盘。
    // 这让解析口径修正或真源重算为 0 后可以自愈，
    // 同时不把缺数据误写成一串永久的零。
    @discardableResult
    static func reconcile(
        _ source: HistorySource,
        authoritativeDays: [(date: String, totalTokens: Int, cost: Double?)]
    ) -> Bool {
        (try? reconcileChecked(source, authoritativeDays: authoritativeDays)) ?? false
    }

    @discardableResult
    static func reconcileChecked(
        _ source: HistorySource,
        authoritativeDays: [(date: String, totalTokens: Int, cost: Double?)]
    ) throws -> Bool {
        try storage.reconcileChecked(source, authoritativeDays: authoritativeDays)
    }

    // 纯函数留给回归测试：测试不需要触碰用户真实的 history.json。
    static func reconciledBucket(
        _ existing: [String: DayEntry],
        authoritativeDays: [(date: String, totalTokens: Int, cost: Double?)]
    ) -> [String: DayEntry] {
        var result = existing
        for day in authoritativeDays {
            if day.totalTokens > 0 {
                result[day.date] = DayEntry(
                    totalTokens: day.totalTokens,
                    cost: day.cost
                )
            } else {
                result.removeValue(forKey: day.date)
            }
        }
        return result
    }

    // 取最近 count 天，每源每天一个值，缺失补 0。返回按日期升序。
    struct DayPoint: Identifiable, Equatable {
        let date: String                       // YYYY-MM-DD
        var bySource: [HistorySource: Int]      // 源 → token
        var cost: Double                        // 当日全源成本合计（目前只有 DeepSeek）
        var costBySource: [HistorySource: Double] = [:]
        var id: String { date }
        var total: Int { bySource.values.reduce(0, +) }

        func cost(for source: HistorySource) -> Double {
            costBySource[source] ?? 0
        }
    }

    static func recent(_ count: Int = 30) -> [DayPoint] {
        (try? storage.recentChecked(count)) ?? []
    }

    // 从本机第一条有效记录到今天，缺失日期同样补 0，供“全部”范围和连续
    // 活跃计算使用。不会读取任何 session，也不会访问网络。
    static func all() -> [DayPoint] {
        (try? allChecked()) ?? []
    }

    static func allChecked(now: Date = Date()) throws -> [DayPoint] {
        try storage.allChecked(now: now)
    }

    fileprivate static func points(table: Table, now today: Date) -> [DayPoint] {
        let todayKey = DateUtil.key(today)
        let validDates = table.values.flatMap(\.keys).compactMap { key -> Date? in
            guard key <= todayKey else { return nil }
            return DateUtil.date(from: key)
        }
        guard let firstDate = validDates.min() else { return [] }
        let count = max(
            (Calendar.current.dateComponents([.day], from: firstDate, to: today).day ?? 0) + 1,
            1
        )
        return (0..<count).map { index in
            point(date: DateUtil.key(DateUtil.addDays(firstDate, index)), table: table)
        }
    }

    fileprivate static func point(date: String, table: Table) -> DayPoint {
        var bySource: [HistorySource: Int] = [:]
        var costBySource: [HistorySource: Double] = [:]
        var cost = 0.0
        for source in HistorySource.allCases {
            if let entry = table[source.rawValue]?[date] {
                bySource[source] = entry.totalTokens
                if let sourceCost = entry.cost {
                    costBySource[source] = sourceCost
                    cost += sourceCost
                }
            }
        }
        return DayPoint(
            date: date,
            bySource: bySource,
            cost: cost,
            costBySource: costBySource
        )
    }
}

/// 与静态默认入口使用同一 JSON 格式；实例 URL 可指向合成测试目录。
struct HistoryFileStore {
    let fileURL: URL
    private let io: HistoryFileIO
    // 同一路径的多实例也必须串行 read-modify-write。
    private static let lock = NSLock()

    init(fileURL: URL, io: HistoryFileIO = HistoryFileIO()) {
        self.fileURL = fileURL
        self.io = io
    }

    @discardableResult
    func recordChecked(
        _ source: HistorySource, days: [(date: String, totalTokens: Int, cost: Double?)]
    ) throws -> Bool {
        guard !days.isEmpty else { return false }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let existing = try readChecked()
        var updated = existing
        var bucket = existing[source.rawValue] ?? [:]
        // 非权威来源仍不把补零天覆盖成真实零。
        for day in days where day.totalTokens > 0 {
            bucket[day.date] = HistoryStore.DayEntry(totalTokens: day.totalTokens, cost: day.cost)
        }
        updated[source.rawValue] = bucket
        guard updated != existing else { return false }
        try io.writeJSON(updated, to: fileURL)
        return true
    }

    @discardableResult
    func reconcileChecked(
        _ source: HistorySource,
        authoritativeDays: [(date: String, totalTokens: Int, cost: Double?)]
    ) throws -> Bool {
        guard !authoritativeDays.isEmpty else { return false }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var table = try readChecked()
        let existing = table[source.rawValue] ?? [:]
        let updated = HistoryStore.reconciledBucket(existing, authoritativeDays: authoritativeDays)
        guard updated != existing else { return false }
        table[source.rawValue] = updated
        try io.writeJSON(table, to: fileURL)
        return true
    }

    func allChecked(now: Date = Date()) throws -> [HistoryStore.DayPoint] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return HistoryStore.points(table: try readChecked(), now: now)
    }

    func recentChecked(_ count: Int = 30, now: Date = Date()) throws -> [HistoryStore.DayPoint] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let table = try readChecked()
        return (0..<max(count, 0)).map { idx in
            HistoryStore.point(date: DateUtil.key(DateUtil.addDays(now, idx - count + 1)), table: table)
        }
    }

    private func readChecked() throws -> HistoryStore.Table {
        try io.readJSON(HistoryStore.Table.self, from: fileURL) ?? [:]
    }
}
