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
    private typealias Table = [String: [String: DayEntry]]

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("TokenMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    private static let lock = NSLock()

    private static func read() -> Table {
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode(Table.self, from: data) else { return [:] }
        return table
    }

    private static func write(_ table: Table) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // 把某源窗口内的按日用量 upsert 进库。days: 日期 → (token, cost?)
    static func record(_ source: HistorySource, days: [(date: String, totalTokens: Int, cost: Double?)]) {
        guard !days.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var table = read()
        var bucket = table[source.rawValue] ?? [:]
        for d in days {
            // 全 0 的补零天不写，避免把"无数据"固化成"0 用量"覆盖真实历史
            guard d.totalTokens > 0 else { continue }
            bucket[d.date] = DayEntry(totalTokens: d.totalTokens, cost: d.cost)
        }
        table[source.rawValue] = bucket
        write(table)
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
        guard !authoritativeDays.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        var table = read()
        let existing = table[source.rawValue] ?? [:]
        let updated = reconciledBucket(existing, authoritativeDays: authoritativeDays)
        guard updated != existing else { return false }
        table[source.rawValue] = updated
        write(table)
        return true
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
        lock.lock(); let table = read(); lock.unlock()
        let now = Date()
        return (0..<count).map { idx in
            let date = DateUtil.key(DateUtil.addDays(now, idx - count + 1))
            return point(date: date, table: table)
        }
    }

    // 从本机第一条有效记录到今天，缺失日期同样补 0，供“全部”范围和连续
    // 活跃计算使用。不会读取任何 session，也不会访问网络。
    static func all() -> [DayPoint] {
        lock.lock(); let table = read(); lock.unlock()
        let today = Date()
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

    private static func point(date: String, table: Table) -> DayPoint {
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
