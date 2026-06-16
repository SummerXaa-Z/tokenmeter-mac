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
    case deepseek, claude, codex, cursor
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

    // 取最近 count 天，每源每天一个值，缺失补 0。返回按日期升序。
    struct DayPoint: Identifiable, Equatable {
        let date: String                       // YYYY-MM-DD
        var bySource: [HistorySource: Int]      // 源 → token
        var cost: Double                        // 当日全源成本合计（目前只有 DeepSeek）
        var id: String { date }
        var total: Int { bySource.values.reduce(0, +) }
    }

    static func recent(_ count: Int = 30) -> [DayPoint] {
        lock.lock(); let table = read(); lock.unlock()
        let now = Date()
        return (0..<count).map { idx -> DayPoint in
            let date = DateUtil.key(DateUtil.addDays(now, idx - count + 1))
            var bySource: [HistorySource: Int] = [:]
            var cost = 0.0
            for src in HistorySource.allCases {
                if let e = table[src.rawValue]?[date] {
                    bySource[src] = e.totalTokens
                    cost += e.cost ?? 0
                }
            }
            return DayPoint(date: date, bySource: bySource, cost: cost)
        }
    }
}
