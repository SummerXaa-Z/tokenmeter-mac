import Foundation

// 按天的用量明细留存。HistoryStore 只存"每源每天一个合计"，模型榜、
// API 等价参考、缓存复用率、Skills 榜与会话数需要"哪天哪个来源发生了什么"，
// 才能跟随 1D / 7D / 30D / 全部切换，并按用量当日生效的价格快照重算。
//
// 落盘位置：~/Library/Application Support/TokenMeter/model-history/YYYY-MM.json，
// 按月分片，结构为 源 → 日期 → 当天明细（模型 Token / Skill 次数 / 会话数）。
// 只保存聚合数字，不含提示词、路径或任何会话内容。
//
// 写入语义与 HistoryStore 对齐：窗口内有数据的天整体替换（同一天多次
// 刷新只留最后一次，不累加）；权威重扫的来源把窗口内已确认无任何明细的
// 天删除，其余来源保留旧值，避免采集器暂时缺数据时抹掉已积累的明细。

// 五类 Token 互斥计数：input 不含缓存，output 不含 reasoning。
// 各采集器的原始口径不同（Codex 的 input 含缓存、output 含 reasoning），
// 统一在采集器出口换算成这里的互斥口径，下游不再重复扣减。
struct ModelTokenTally: Codable, Equatable {
    var input: Int
    var cached: Int
    var cacheWrite: Int
    var output: Int
    var reasoning: Int

    init(input: Int = 0, cached: Int = 0, cacheWrite: Int = 0,
         output: Int = 0, reasoning: Int = 0) {
        self.input = max(input, 0)
        self.cached = max(cached, 0)
        self.cacheWrite = max(cacheWrite, 0)
        self.output = max(output, 0)
        self.reasoning = max(reasoning, 0)
    }

    var total: Int {
        [cached, cacheWrite, output, reasoning].reduce(input, Self.saturatingAdd)
    }

    // 全部提示侧 Token：缓存复用率的分母
    var promptTokens: Int {
        [cached, cacheWrite].reduce(input, Self.saturatingAdd)
    }

    var isEmpty: Bool { total == 0 }

    // 采集器出口统一剔除全 0 模型；整天为空返回 nil，配合 compactMapValues。
    static func nonEmpty(_ models: [String: ModelTokenTally]) -> [String: ModelTokenTally]? {
        let kept = models.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        return kept.isEmpty ? nil : kept
    }

    var breakdown: APITokenBreakdown {
        APITokenBreakdown(
            newInputTokens: input,
            cachedInputTokens: cached,
            cacheCreationTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning
        )
    }

    static func + (lhs: ModelTokenTally, rhs: ModelTokenTally) -> ModelTokenTally {
        ModelTokenTally(
            input: saturatingAdd(lhs.input, rhs.input),
            cached: saturatingAdd(lhs.cached, rhs.cached),
            cacheWrite: saturatingAdd(lhs.cacheWrite, rhs.cacheWrite),
            output: saturatingAdd(lhs.output, rhs.output),
            reasoning: saturatingAdd(lhs.reasoning, rhs.reasoning)
        )
    }

    static func += (lhs: inout ModelTokenTally, rhs: ModelTokenTally) {
        lhs = lhs + rhs
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    // 短键 + 省略 0 值：一年明细也只有几百 KB
    private enum CodingKeys: String, CodingKey {
        case input = "in", cached = "cr", cacheWrite = "cw", output = "out", reasoning = "rs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: try c.decodeIfPresent(Int.self, forKey: .input) ?? 0,
            cached: try c.decodeIfPresent(Int.self, forKey: .cached) ?? 0,
            cacheWrite: try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0,
            output: try c.decodeIfPresent(Int.self, forKey: .output) ?? 0,
            reasoning: try c.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if input > 0 { try c.encode(input, forKey: .input) }
        if cached > 0 { try c.encode(cached, forKey: .cached) }
        if cacheWrite > 0 { try c.encode(cacheWrite, forKey: .cacheWrite) }
        if output > 0 { try c.encode(output, forKey: .output) }
        if reasoning > 0 { try c.encode(reasoning, forKey: .reasoning) }
    }
}

// 单个来源一天的全部明细：模型 Token 五分类、Skill 调用次数、活跃会话数。
// 任意一项有值即算有明细（会话开了但没耗 token 的天也要留住）。
// 编码用短键；"m" 键恒写入——它同时是新旧格式的判别标记（旧分片的日期
// 下直接挂 模型 → Token，没有 "m" 键）。
struct SourceDayDetail: Codable, Equatable {
    var models: [String: ModelTokenTally]
    var skills: [String: Int]
    var sessions: Int

    init(
        models: [String: ModelTokenTally] = [:],
        skills: [String: Int] = [:],
        sessions: Int = 0
    ) {
        self.models = ModelTokenTally.nonEmpty(models) ?? [:]
        self.skills = skills.filter { !$0.key.isEmpty && $0.value > 0 }
        self.sessions = max(sessions, 0)
    }

    var isEmpty: Bool { models.isEmpty && skills.isEmpty && sessions <= 0 }

    private enum CodingKeys: String, CodingKey {
        case models = "m", skills = "sk", sessions = "se"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.models) {
            self.init(
                models: try c.decodeIfPresent([String: ModelTokenTally].self, forKey: .models) ?? [:],
                skills: try c.decodeIfPresent([String: Int].self, forKey: .skills) ?? [:],
                sessions: try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
            )
        } else {
            // 旧格式：日期直挂 模型 → Token
            let old = try decoder.singleValueContainer()
                .decode([String: ModelTokenTally].self)
            self.init(models: old)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(models, forKey: .models)
        if !skills.isEmpty { try c.encode(skills, forKey: .skills) }
        if sessions > 0 { try c.encode(sessions, forKey: .sessions) }
    }
}

struct ModelUsageDay: Equatable {
    let date: String                                       // YYYY-MM-DD
    var bySource: [HistorySource: SourceDayDetail]         // 源 → 当天明细
}

struct ModelUsageHistoryStore {
    // 单个月份分片：源 → 日期 → 当天明细
    typealias Shard = [String: [String: SourceDayDetail]]

    static let shared = ModelUsageHistoryStore(directory: defaultDirectory)

    static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("TokenMeter", isDirectory: true)
        .appendingPathComponent("model-history", isDirectory: true)

    // 所有实例共用一把锁：同一目录可能被多个来源的刷新并发写入
    private static let lock = NSLock()

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    // 把某源一次刷新的窗口写入明细。windowDates 是本次扫描覆盖的日期
    // （含补零天），days 是其中有明细的天。返回是否有分片发生变化。
    @discardableResult
    func write(
        _ source: HistorySource,
        windowDates: [String],
        days: [String: SourceDayDetail],
        deletesEmptyDays: Bool
    ) -> Bool {
        let cleaned = Self.cleaned(days)
        let dates = Set(windowDates).union(cleaned.keys).filter(Self.isDateKey)
        guard !dates.isEmpty else { return false }
        let datesByMonth = Dictionary(grouping: dates) { String($0.prefix(7)) }

        Self.lock.lock(); defer { Self.lock.unlock() }
        var changed = false
        for (month, monthDates) in datesByMonth {
            let existing = readShard(month)
            let updated = Self.merged(
                existing, source: source, dates: Set(monthDates),
                days: cleaned, deletesEmptyDays: deletesEmptyDays)
            guard updated != existing else { continue }
            writeShard(updated, month: month)
            changed = true
        }
        return changed
    }

    // 纯函数留给回归测试：不触碰用户真实的明细目录。
    static func merged(
        _ shard: Shard,
        source: HistorySource,
        dates: Set<String>,
        days: [String: SourceDayDetail],
        deletesEmptyDays: Bool
    ) -> Shard {
        var result = shard
        var bucket = result[source.rawValue] ?? [:]
        for date in dates {
            if let detail = days[date], !detail.isEmpty {
                bucket[date] = detail
            } else if deletesEmptyDays {
                bucket.removeValue(forKey: date)
            }
        }
        if bucket.isEmpty {
            result.removeValue(forKey: source.rawValue)
        } else {
            result[source.rawValue] = bucket
        }
        return result
    }

    // 全部有明细的天，按日期升序；不补零，缺明细的天由调用方决定如何呈现。
    func all() -> [ModelUsageDay] {
        Self.lock.lock()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let shards = names.filter(Self.isShardFileName).map { readShard(String($0.prefix(7))) }
        Self.lock.unlock()

        var byDate: [String: [HistorySource: SourceDayDetail]] = [:]
        for shard in shards {
            for (rawSource, dates) in shard {
                guard let source = HistorySource(rawValue: rawSource) else { continue }
                for (date, detail) in dates where Self.isDateKey(date) && !detail.isEmpty {
                    byDate[date, default: [:]][source] = detail
                }
            }
        }
        return byDate.keys.sorted().map { ModelUsageDay(date: $0, bySource: byDate[$0] ?? [:]) }
    }

    private func shardURL(_ month: String) -> URL {
        directory.appendingPathComponent("\(month).json")
    }

    private func readShard(_ month: String) -> Shard {
        guard let data = try? Data(contentsOf: shardURL(month)),
              let shard = try? JSONDecoder().decode(Shard.self, from: data) else { return [:] }
        return shard
    }

    private func writeShard(_ shard: Shard, month: String) {
        let url = shardURL(month)
        if shard.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(shard) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func cleaned(_ days: [String: SourceDayDetail]) -> [String: SourceDayDetail] {
        var result: [String: SourceDayDetail] = [:]
        for (date, detail) in days where isDateKey(date) {
            let normalized = SourceDayDetail(
                models: detail.models, skills: detail.skills, sessions: detail.sessions)
            guard !normalized.isEmpty else { continue }
            result[date] = normalized
        }
        return result
    }

    static func isDateKey(_ key: String) -> Bool {
        let chars = Array(key.utf8)
        guard chars.count == 10 else { return false }
        return chars.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 ? byte == UInt8(ascii: "-") : (48...57).contains(byte)
        }
    }

    private static func isShardFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), name.utf8.count == 12 else { return false }
        return isDateKey(String(name.prefix(7)) + "-01")
    }
}
