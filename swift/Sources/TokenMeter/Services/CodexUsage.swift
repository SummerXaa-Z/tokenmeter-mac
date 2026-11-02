import Foundation

// Codex CLI 用量解析：纯本地读 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl，
// 本地用量扫描零网络、零凭据；官方实时配额是独立的默认关闭选项。
//
// 归因口径：session 文件里每条 token_count 事件带累计 total_token_usage，
// 用相邻事件的差值（cumulative diff）归到事件时间戳当天。跨天 session
// 的用量会正确拆分到各天，而不是全记到 session 开始日。
// 配额 rate_limits 取全部事件中时间戳最新的一条。
//
// 单文件可达数百 MB，顺序分块流式扫描（8MB chunk），只解码含
// token_count 标记的行；按 (size, mtime, calendar) 做内存级缓存，刷新时未变的
// 文件不重扫。

struct CodexRateWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

struct CodexRateLimits: Equatable {
    let limitId: String?              // 通道 id：codex=订阅配额，其余为灰度/实验通道
    let limitName: String?            // 通道展示名（如 GPT-5.3-Codex-Spark）
    let primary: CodexRateWindow?     // 5 小时窗
    let secondary: CodexRateWindow?   // 周窗（10080 分钟）
    let planType: String?
    let asOf: Date                    // 数据时刻（事件时间戳）

    var isMain: Bool { limitId == nil || limitId == "codex" }
}

struct CodexDayUsage: Equatable, Identifiable {
    let date: String                  // "YYYY-MM-DD"
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var totalTokens: Int = 0
    var sessionCount: Int = 0

    var id: String { date }
    var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens) * 100
    }
}

struct CodexModelUsage: Equatable, Identifiable {
    let model: String            // 含 effort 后缀，如 "gpt-5.5 (xhigh)"
    var totalTokens: Int = 0
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var id: String { model }
}

struct CodexProjectUsage: Equatable, Identifiable {
    let project: String          // session_meta cwd 末段
    var totalTokens: Int = 0
    var sessionCount: Int = 0
    var id: String { project }
}

struct CodexSkillUsage: Equatable, Identifiable {
    let name: String
    var invocationCount: Int
    var id: String { name }
}

struct CodexUsageResult: Equatable {
    let rateLimits: CodexRateLimits?       // 主通道（订阅配额）
    let allRateLimits: [CodexRateLimits]   // 全部通道，主通道在前
    let days: [CodexDayUsage]         // 最近 7 天，缺失日补零，升序
    let models: [CodexModelUsage]     // 7 天窗口按模型聚合，按量降序
    let projects: [CodexProjectUsage] // 7 天窗口按项目聚合，按量降序
    let todayHours: [CodexHourUsage]  // 今日 24 小时分布
    let skills: [CodexSkillUsage]     // 近 7 天实际读取 SKILL.md 的工具调用
    // 日期 → 模型 → 互斥五类 Token（已从 input 扣缓存、从 output 扣 reasoning）
    var dayModels: [String: [String: ModelTokenTally]] = [:]
    // 日期 → Skill 名 → 调用次数，与 dayModels 同窗口同语义
    var daySkills: [String: [String: Int]] = [:]
    // 有读取失败时聚合可能不完整，不得据此覆盖已保存的完整历史。
    var readError: String? = nil
    var isAuthoritative: Bool { readError == nil }
    var today: CodexDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
    // 日期 → 活跃会话数，供按天落盘
    var daySessions: [String: Int] {
        days.reduce(into: [:]) { result, day in
            if day.sessionCount > 0 { result[day.date] = day.sessionCount }
        }
    }
}

struct CodexHourUsage: Equatable, Identifiable {
    let hour: Int
    let totalTokens: Int
    var id: Int { hour }
}

enum CodexUsage {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: sessionsDir.path)
    }

    // MARK: - JSONL 事件解码（只取需要的字段）

    private struct Event: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let id: String?         // session_meta 的稳定会话标识
            let forkedFromID: String?
            let type: String?
            let info: Info?
            let rateLimits: RateLimits?
            let model: String?       // turn_context
            let effort: String?      // turn_context
            let cwd: String?         // session_meta / turn_context
            let name: String?        // response_item 工具名
            let callId: String?
            let arguments: LossyString?
            let input: LossyString?
            enum CodingKeys: String, CodingKey {
                case id, type, info, model, effort, cwd, name, arguments, input
                case forkedFromID = "forked_from_id"
                case callId = "call_id"
                case rateLimits = "rate_limits"
            }
        }
        // 工具参数有时是字符串、有时是对象。Skills 识别只接受字符串路径；
        // 其他形态静默忽略，避免一处 schema 演进让整行解码失败。
        struct LossyString: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                value = try? container.decode(String.self)
            }
        }
        struct Info: Decodable {
            let totalTokenUsage: TokenUsage?
            let lastTokenUsage: TokenUsage?
            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
                case lastTokenUsage = "last_token_usage"
            }
        }
        struct TokenUsage: Decodable, Hashable {
            let inputTokens: Int?
            let cachedInputTokens: Int?
            let outputTokens: Int?
            let reasoningOutputTokens: Int?
            let totalTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case outputTokens = "output_tokens"
                case reasoningOutputTokens = "reasoning_output_tokens"
                case totalTokens = "total_tokens"
            }
        }
        struct RateLimits: Decodable {
            let limitId: String?
            let limitName: String?
            let primary: Window?
            let secondary: Window?
            let planType: String?
            enum CodingKeys: String, CodingKey {
                case primary, secondary
                case limitId = "limit_id"
                case limitName = "limit_name"
                case planType = "plan_type"
            }
        }
        struct Window: Decodable {
            let usedPercent: Double?
            let windowMinutes: Int?
            let resetsAt: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }
        }
    }

    // MARK: - 单文件扫描结果与缓存

    private struct Tally: Equatable {
        var input = 0, cached = 0, output = 0, reasoning = 0, total = 0
    }

    private struct FileSummary {
        let size: UInt64
        let mtime: Date
        let calendar: Calendar
        let sessionID: String?
        let parentSessionID: String?
        let forkedAt: Date?
        let events: [TokenEvent]
        let project: String?                 // session cwd 末段（每文件一个）
        let rateLimitsByChannel: [String: CodexRateLimits]  // 通道 → 该文件内最新快照
        let skills: [SkillEvent]
    }

    // 只缓存用量/工具标识，不缓存命令、会话正文或 cwd 原文。累计事件要在
    // 同一 session 的全部副本合并后再差分，才能正确处理仅含后半段的续写文件。
    private struct TokenEvent {
        let key: TokenEventKey
        let model: String
        let last: Event.TokenUsage?
    }
    private struct TokenEventKey: Hashable {
        let timestamp: Date
        let total: Event.TokenUsage
    }
    private struct SkillEvent {
        let timestamp: Date
        let key: String
        let name: String
    }
    private struct SessionSummary {
        var events: [TokenEvent] = []
        var eventIndices: [TokenEventKey: Int] = [:]
        var skills: [SkillEvent] = []
        var parentID: String?
        var forkedAt: Date?
        var project: String?
    }
    private struct SessionMetadata {
        let size: UInt64
        let mtime: Date
        let id: String?
        let parentID: String?
    }

    // 内存级缓存：app 存续期内，未变的文件不重扫
    private static var cache: [String: FileSummary] = [:]
    private static var metadataCache: [String: SessionMetadata] = [:]
    private static let cacheLock = NSLock()

    // MARK: - 入口

    // 全树扫描，按 mtime 过滤：长期复用的 session（Codex Desktop 可挂数周）
    // 落在很老的日期目录里，但只要还在写 mtime 就是新的，按目录日期扫会漏掉。
    // mtime 早于窗口的文件只为相同 session/显式父链补读累计基线。
    static func load(
        sessionsDirectory: URL = sessionsDir,
        now: Date = Date(),
        windowDays: Int = 7
    ) -> CodexUsageResult {
        let fm = FileManager.default
        let calendar = Calendar.current
        var readError: String?
        let span = max(windowDays, 1)
        var dayMap: [String: CodexDayUsage] = [:]
        let window: Set<String> = Set((0..<span).map { DateUtil.key(DateUtil.addDays(now, -$0)) })
        for key in window { dayMap[key] = CodexDayUsage(date: key) }
        let windowStart = Calendar.current.startOfDay(for: DateUtil.addDays(now, 1 - span))

        var limitsByChannel: [String: CodexRateLimits] = [:]
        var modelMap: [String: CodexModelUsage] = [:]
        var dayModels: [String: [String: ModelTokenTally]] = [:]
        var daySkills: [String: [String: Int]] = [:]
        var projectMap: [String: CodexProjectUsage] = [:]
        var skillMap: [String: Int] = [:]
        var hourMap: [Int: Int] = [:]
        let todayKey = DateUtil.key(now)
        var files: [(path: String, summary: FileSummary)] = []
        var olderFiles: [(file: URL, size: UInt64, mtime: Date)] = []

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(
            at: sessionsDirectory, includingPropertiesForKeys: keys,
            errorHandler: { _, _ in
                readError = readError ?? "本地会话目录读取失败"
                return true
            }
        ) else {
            return CodexUsageResult(rateLimits: nil, allRateLimits: [],
                                    days: dayMap.values.sorted { $0.date < $1.date },
                                    models: [], projects: [], todayHours: [], skills: [],
                                    readError: "本地会话目录读取失败")
        }

        for case let file as URL in walker where file.pathExtension == "jsonl" {
            let attrs: URLResourceValues
            do {
                attrs = try file.resourceValues(forKeys: Set(keys))
            } catch {
                readError = readError ?? "本地会话属性读取失败"
                continue
            }
            guard let isRegularFile = attrs.isRegularFile else {
                readError = readError ?? "本地会话属性读取失败"
                continue
            }
            guard isRegularFile else { continue }
            guard let mtime = attrs.contentModificationDate,
                  let size = attrs.fileSize, size >= 0 else {
                readError = readError ?? "本地会话属性读取失败"
                continue
            }
            if mtime < windowStart {
                olderFiles.append((file, UInt64(size), mtime))
                continue
            }
            let summary: FileSummary
            do {
                summary = try summarize(file, size: UInt64(size), mtime: mtime, calendar: calendar)
            } catch {
                // 只返回阶段摘要，系统错误中的路径与会话内容不进入诊断。
                readError = readError ?? "本地会话文件读取失败"
                continue
            }
            files.append((file.path, summary))
        }

        // 仅含后半段的续写文件需要旧副本的累计基线。旧文件先读有界元数据，
        // 只为当前 session 或显式父链补读内容；无关历史不做完整扫描。
        var wantedIDs = Set(files.compactMap { $0.summary.sessionID })
        wantedIDs.formUnion(files.compactMap { $0.summary.parentSessionID })
        if !wantedIDs.isEmpty {
            var older: [(file: URL, size: UInt64, mtime: Date, meta: SessionMetadata)] = []
            for candidate in olderFiles {
                do {
                    let meta = try metadata(candidate.file, size: candidate.size, mtime: candidate.mtime)
                    older.append((candidate.file, candidate.size, candidate.mtime, meta))
                } catch {
                    readError = readError ?? "本地会话基线读取失败"
                }
            }
            var included = Set<String>()
            var added = true
            while added {
                added = false
                for candidate in older {
                    guard let id = candidate.meta.id, wantedIDs.contains(id),
                          included.insert(candidate.file.path).inserted else { continue }
                    do {
                        let summary = try summarize(candidate.file, size: candidate.size,
                                                    mtime: candidate.mtime, calendar: calendar)
                        files.append((candidate.file.path, summary))
                        if let parent = summary.parentSessionID, wantedIDs.insert(parent).inserted { added = true }
                    } catch {
                        readError = readError ?? "本地会话基线读取失败"
                    }
                }
            }
        }

        var sessions: [String: SessionSummary] = [:]
        // 路径仅作缺元数据时的保守身份和稳定择优顺序，不输出或持久化。
        for file in files.sorted(by: { $0.path < $1.path }) {
            let summary = file.summary
            let id = summary.sessionID.map { "session:\($0)" } ?? "file:\(file.path)"
            var session = sessions[id] ?? SessionSummary()
            for event in summary.events {
                if let index = session.eventIndices[event.key] {
                    if session.events[index].model == "unknown", event.model != "unknown" {
                        session.events[index] = event
                    }
                } else {
                    session.eventIndices[event.key] = session.events.count
                    session.events.append(event)
                }
            }
            session.skills += summary.skills
            session.parentID = summary.parentSessionID.map { "session:\($0)" } ?? session.parentID
            session.forkedAt = summary.forkedAt ?? session.forkedAt
            session.project = session.project ?? summary.project
            sessions[id] = session
            for (channel, rl) in summary.rateLimitsByChannel {
                if let prev = limitsByChannel[channel], prev.asOf >= rl.asOf { continue }
                limitsByChannel[channel] = rl
            }
        }

        func family(of id: String) -> String {
            var current = id
            var visited: Set<String> = []
            while let parent = sessions[current]?.parentID {
                guard visited.insert(current).inserted else { return visited.min() ?? id }
                current = parent
            }
            // 异常循环元数据不能使扫描卡住，也不能凭猜测合并独立会话。
            return current
        }
        func depth(of id: String) -> Int {
            var current = id
            var visited: Set<String> = []
            while visited.insert(current).inserted, let parent = sessions[current]?.parentID {
                current = parent
            }
            return visited.count
        }
        func counter(in id: String, before cutoff: Date, visited: Set<String> = []) -> TokenEvent? {
            guard !visited.contains(id), let session = sessions[id] else { return nil }
            let current = session.events.enumerated().filter { $0.element.key.timestamp <= cutoff }
                .max(by: {
                    if $0.element.key.timestamp != $1.element.key.timestamp {
                        return $0.element.key.timestamp < $1.element.key.timestamp
                    }
                    return $0.offset < $1.offset
                })?.element
            guard let parentID = session.parentID, let forkedAt = session.forkedAt,
                  let inherited = counter(in: parentID, before: min(cutoff, forkedAt),
                                          visited: visited.union([id])) else { return current }
            // 父分支也可能只有续写片段，或复制的前缀早于其真正继承基线。
            guard let current else { return inherited }
            if current.key.timestamp < inherited.key.timestamp { return inherited }
            if current.key.timestamp == inherited.key.timestamp,
               current.key.timestamp < forkedAt
                || sessions[parentID]?.eventIndices[current.key] != nil { return inherited }
            return current
        }

        var seenFamilyEvents: [String: Set<TokenEventKey>] = [:]
        var seenFamilySkills: [String: Set<String>] = [:]
        var daySessions: [String: Set<String>] = [:]
        // 先接受父会话，再去掉 fork 中拷贝的前缀；每个分支先独立差分，
        // 不能把不同分支的累计值串成一条序列，否则会吞掉真正的分支增量。
        let orderedIDs = sessions.keys.sorted {
            let left = depth(of: $0), right = depth(of: $1)
            return left == right ? $0 < $1 : left < right
        }
        for id in orderedIDs {
            guard let session = sessions[id] else { continue }
            let familyID = family(of: id)
            // fork 续写文件可能只保留新分支的后半段，没有复制的累计前缀。
            // 用父会话在分叉时的最后一个累计值作基线，不能把继承的用量
            // 当成该分支的首个新请求。父会话后续增长不属于这个基线。
            let inheritedBaseline: TokenEvent? = {
                guard let parentID = session.parentID, let forkedAt = session.forkedAt else { return nil }
                return counter(in: parentID, before: forkedAt)
            }()
            var prevTotal = inheritedBaseline?.key.total
            var sessionTokens = 0
            var counted = false
            let events = session.events.enumerated().sorted {
                if $0.element.key.timestamp != $1.element.key.timestamp {
                    return $0.element.key.timestamp < $1.element.key.timestamp
                }
                return $0.offset < $1.offset
            }
            for entry in events {
                let event = entry.element
                if let inheritedBaseline, let forkedAt = session.forkedAt,
                   event.key.timestamp <= forkedAt,
                   event.key.timestamp < inheritedBaseline.key.timestamp
                    || event.key == inheritedBaseline.key
                    || session.parentID.flatMap({ sessions[$0]?.eventIndices[event.key] }) != nil {
                    // 即使复制的前缀不完整，也不能把基线倒退回更早的累计值。
                    seenFamilyEvents[familyID, default: []].insert(event.key)
                    continue
                }
                let tokens = delta(event.key.total, prevTotal, fallback: event.last)
                prevTotal = event.key.total
                let isNew = seenFamilyEvents[familyID, default: []].insert(event.key).inserted
                let isInherited = session.parentID == nil
                    || (session.forkedAt.map { event.key.timestamp <= $0 } ?? true)
                guard isNew || !isInherited else { continue }
                let date = DateUtil.key(event.key.timestamp)
                guard window.contains(date) else { continue }
                var d = dayMap[date] ?? CodexDayUsage(date: date)
                d.inputTokens += tokens.input
                d.cachedInputTokens += tokens.cached
                d.outputTokens += tokens.output
                d.reasoningTokens += tokens.reasoning
                d.totalTokens += tokens.total
                dayMap[date] = d
                daySessions[date, default: []].insert(id)
                counted = true
                sessionTokens += tokens.total
                let model = event.model
                var m = modelMap[model] ?? CodexModelUsage(model: model)
                m.totalTokens += tokens.total
                m.inputTokens += tokens.input
                m.cachedInputTokens += tokens.cached
                m.outputTokens += tokens.output
                m.reasoningTokens += tokens.reasoning
                modelMap[model] = m
                dayModels[date, default: [:]][model, default: .init()] += ModelTokenTally(
                    input: max(tokens.input - tokens.cached, 0), cached: tokens.cached,
                    output: max(tokens.output - tokens.reasoning, 0), reasoning: tokens.reasoning)
                if date == todayKey {
                    let hour = calendar.component(.hour, from: event.key.timestamp)
                    hourMap[hour, default: 0] += tokens.total
                }
            }
            for skill in session.skills.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard seenFamilySkills[familyID, default: []].insert(skill.key).inserted else { continue }
                let date = DateUtil.key(skill.timestamp)
                guard window.contains(date) else { continue }
                skillMap[skill.name, default: 0] += 1
                daySkills[date, default: [:]][skill.name, default: 0] += 1
            }
            if counted {
                let project = session.project ?? "(其他)"
                var row = projectMap[project] ?? CodexProjectUsage(project: project)
                row.totalTokens += sessionTokens
                row.sessionCount += 1
                projectMap[project] = row
            }
        }
        for (date, ids) in daySessions { dayMap[date]?.sessionCount = ids.count }

        let days = dayMap.values.sorted { $0.date < $1.date }
        let models = modelMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let projects = projectMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let todayHours = (0..<24).map { CodexHourUsage(hour: $0, totalTokens: hourMap[$0] ?? 0) }
        let skills = skillMap.map { CodexSkillUsage(name: $0.key, invocationCount: $0.value) }
            .sorted {
                if $0.invocationCount != $1.invocationCount {
                    return $0.invocationCount > $1.invocationCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        // 主通道在前，其余按数据新鲜度降序
        let channels = limitsByChannel.values.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.asOf > $1.asOf
        }
        return CodexUsageResult(rateLimits: channels.first, allRateLimits: channels, days: days,
                                models: models, projects: projects, todayHours: todayHours,
                                skills: skills,
                                dayModels: dayModels.compactMapValues(ModelTokenTally.nonEmpty),
                                daySkills: daySkills, readError: readError)
    }

    // MARK: - 单文件流式扫描（带缓存）

    private static func metadata(_ file: URL, size: UInt64, mtime: Date) throws -> SessionMetadata {
        cacheLock.lock()
        let hit = metadataCache[file.path]
        let complete = cache[file.path]
        cacheLock.unlock()
        if let hit, hit.size == size, hit.mtime == mtime { return hit }
        let result: SessionMetadata
        if let complete, complete.size == size, complete.mtime == mtime {
            result = SessionMetadata(size: size, mtime: mtime,
                                     id: complete.sessionID, parentID: complete.parentSessionID)
        } else {
            // 官方 session_meta 位于文件首行。只解码有界首段，不能为了判断
            // 亲缘把无关历史正文加载进内存；未识别到 ID 的文件保持独立。
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: 64 * 1024) ?? Data()
            let marker = Data("\"session_meta\"".utf8)
            let row = head.split(separator: 0x0A).first { $0.range(of: marker) != nil }
                .flatMap { try? JSONDecoder().decode(Event.self, from: Data($0)) }
            let payload = (row?.type == "session_meta" || row?.payload?.type == "session_meta")
                ? row?.payload : nil
            let id = payload?.id.flatMap { $0.isEmpty ? nil : $0 }
            let parent = payload?.forkedFromID.flatMap { $0.isEmpty ? nil : $0 }
            result = SessionMetadata(size: size, mtime: mtime, id: id, parentID: parent)
        }
        cacheLock.lock()
        metadataCache[file.path] = result
        cacheLock.unlock()
        return result
    }

    private static func summarize(
        _ file: URL, size: UInt64, mtime: Date, calendar: Calendar
    ) throws -> FileSummary {
        // 权限可能改变而 size/mtime 不变；缓存不能掩盖当前的读取失败。
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw CocoaError(.fileReadNoPermission)
        }

        cacheLock.lock()
        let hit = cache[file.path]
        cacheLock.unlock()
        if let hit, hit.size == size, hit.mtime == mtime, hit.calendar == calendar { return hit }

        let summary = try scan(file, size: size, mtime: mtime, calendar: calendar)
        cacheLock.lock()
        cache[file.path] = summary
        cacheLock.unlock()
        return summary
    }

    private static func scan(
        _ file: URL, size: UInt64, mtime: Date, calendar: Calendar
    ) throws -> FileSummary {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let marker = Data("\"token_count\"".utf8)
        let ctxMarker = Data("\"turn_context\"".utf8)
        let metaMarker = Data("\"session_meta\"".utf8)
        let skillMarker = Data("SKILL.md".utf8)
        let newline = UInt8(ascii: "\n")
        let chunkSize = 8 * 1024 * 1024
        let decoder = JSONDecoder()

        var sessionID: String?
        var parentSessionID: String?
        var forkedAt: Date?
        var events: [TokenEvent] = []
        var project: String?
        var currentModel = "unknown"     // turn_context 声明后续 turn 的模型
        var rlByChannel: [String: CodexRateLimits] = [:]
        var skills: [SkillEvent] = []
        var seenSkillCalls = Set<String>()
        var carry = Data()   // chunk 边界上的半行

        var reachedEnd = false
        while !reachedEnd {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            var data: Data
            if chunk.isEmpty {
                // JSONL 写入过程里最后一行不一定立刻带换行；EOF 时把完整残留行当作一行消费。
                // 若它确实仍是不完整 JSON，下面的 decode 自然失败并安全跳过。
                guard !carry.isEmpty else { break }
                data = carry
                data.append(newline)
                carry = Data()
                reachedEnd = true
            } else if carry.isEmpty {
                data = chunk
            } else {
                data = carry + chunk
                carry = Data()
            }

            var lineStart = data.startIndex
            while lineStart < data.endIndex {
                guard let nl = data[lineStart...].firstIndex(of: newline) else {
                    carry = data[lineStart...]   // 行未结束，留到下个 chunk
                    break
                }
                let line = data[lineStart..<nl]
                lineStart = data.index(after: nl)

                // 只在 response_item 的真实工具调用里识别标准 Skill 路径。
                // 参数字符串仅在这一小段内做路径匹配，结果不会保留命令、路径或正文。
                if line.range(of: skillMarker) != nil,
                   let event = try? decoder.decode(Event.self, from: line),
                   event.type == "response_item",
                   let payload = event.payload,
                   payload.type == "function_call" || payload.type == "custom_tool_call",
                   isReadLikeSkillCall(name: payload.name, payload: payload),
                   let ts = event.timestamp.flatMap({ ISO8601DateFormatter.codex.date(from: $0) }) {
                    let texts = [payload.arguments?.value, payload.input?.value].compactMap { $0 }
                    let names = Set(texts.flatMap(skillNames(in:)))
                    for name in names {
                        let key = "\(payload.callId ?? event.timestamp ?? "")|\(name.lowercased())"
                        guard seenSkillCalls.insert(key).inserted else { continue }
                        skills.append(SkillEvent(timestamp: ts, key: key, name: name))
                    }
                }

                // 轻量行:turn_context 行更新当前模型,session_meta 行取项目
                if line.range(of: ctxMarker) != nil || line.range(of: metaMarker) != nil {
                    if let event = try? decoder.decode(Event.self, from: line) {
                        if event.type == "session_meta" || event.payload?.type == "session_meta" {
                            if let id = event.payload?.id, !id.isEmpty { sessionID = id }
                            if let parent = event.payload?.forkedFromID, !parent.isEmpty {
                                parentSessionID = parent
                                forkedAt = event.timestamp.flatMap { ISO8601DateFormatter.codex.date(from: $0) }
                            }
                        }
                        if let m = event.payload?.model {
                            let effort = event.payload?.effort
                            currentModel = effort.map { "\(m) (\($0))" } ?? m
                        }
                        if project == nil, let cwd = event.payload?.cwd, !cwd.isEmpty {
                            let name = (cwd as NSString).lastPathComponent
                            project = name.isEmpty ? nil : name
                        }
                    }
                    continue
                }
                guard line.range(of: marker) != nil,
                      let event = try? decoder.decode(Event.self, from: line),
                      event.payload?.type == "token_count" else { continue }

                let ts = event.timestamp.flatMap { ISO8601DateFormatter.codex.date(from: $0) }

                if let cur = event.payload?.info?.totalTokenUsage, let ts {
                    events.append(TokenEvent(
                        key: TokenEventKey(timestamp: ts, total: cur), model: currentModel,
                        last: event.payload?.info?.lastTokenUsage))
                }

                if let rl = event.payload?.rateLimits, let ts {
                    let p = rl.primary.flatMap(window)
                    let s = rl.secondary.flatMap(window)
                    // 两个窗口都空的事件（偶发 primary: null）不顶掉有效快照。
                    // 按 limit_id 分通道各存最新：codex 是订阅配额，灰度通道
                    // （如 codex_bengalfox）单独留快照，上游切换通道时 UI 全量呈现
                    guard p != nil || s != nil else { continue }
                    let channel = rl.limitId ?? "codex"
                    let snapshot = CodexRateLimits(
                        limitId: rl.limitId, limitName: rl.limitName,
                        primary: p, secondary: s, planType: rl.planType, asOf: ts)
                    if let prev = rlByChannel[channel], prev.asOf >= ts { continue }
                    rlByChannel[channel] = snapshot
                }
            }
        }
        return FileSummary(size: size, mtime: mtime, calendar: calendar,
                           sessionID: sessionID, parentSessionID: parentSessionID,
                           forkedAt: forkedAt, events: events, project: project,
                           rateLimitsByChannel: rlByChannel, skills: skills)
    }

    private static func isReadLikeSkillCall(name: String?, payload: Event.Payload) -> Bool {
        let tool = name?.lowercased() ?? ""
        if ["read", "read_file", "readfile", "view_file"].contains(tool) { return true }
        guard ["exec", "exec_command", "shell", "bash", "run_command"].contains(tool) else {
            return false
        }
        let command = [payload.arguments?.value, payload.input?.value]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let readCommands = [
            "cat ", "sed ", "head ", "tail ", "less ", "more ", "bat ",
            "rg ", "grep ", "awk ", "perl ", "wc ", "get-content",
        ]
        return readCommands.contains { command.contains($0) }
    }

    private static func skillNames(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return skillPathPattern.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            return normalizedSkillName(String(text[nameRange]))
        }
    }

    private static func normalizedSkillName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }

    private static let skillPathPattern = try! NSRegularExpression(
        pattern: #"(?:^|[/\\])skills?[/\\]([^/\\\s\"']+)[/\\]SKILL\.md\b"#,
        options: [.caseInsensitive]
    )

    private static func delta(_ cur: Event.TokenUsage, _ prev: Event.TokenUsage?,
                              fallback: Event.TokenUsage?) -> Tally {
        let curTotal = cur.totalTokens ?? 0
        if let prev, curTotal < (prev.totalTokens ?? 0) {
            // 累计被重置（如 compaction），用本轮用量兜底
            let f = fallback ?? cur
            return Tally(input: f.inputTokens ?? 0, cached: f.cachedInputTokens ?? 0,
                         output: f.outputTokens ?? 0, reasoning: f.reasoningOutputTokens ?? 0,
                         total: f.totalTokens ?? 0)
        }
        return Tally(
            input: max((cur.inputTokens ?? 0) - (prev?.inputTokens ?? 0), 0),
            cached: max((cur.cachedInputTokens ?? 0) - (prev?.cachedInputTokens ?? 0), 0),
            output: max((cur.outputTokens ?? 0) - (prev?.outputTokens ?? 0), 0),
            reasoning: max((cur.reasoningOutputTokens ?? 0) - (prev?.reasoningOutputTokens ?? 0), 0),
            total: max(curTotal - (prev?.totalTokens ?? 0), 0))
    }

    private static func window(_ w: Event.Window) -> CodexRateWindow? {
        guard let pct = w.usedPercent, let minutes = w.windowMinutes else { return nil }
        let resets = Date(timeIntervalSince1970: w.resetsAt ?? 0)
        return CodexRateWindow(usedPercent: pct, windowMinutes: minutes, resetsAt: resets)
    }

    // MARK: - 实时配额（官方接口）

    // 本地快照是被动的：只有对应通道发生请求才落盘，切灰度模型后订阅配额
    // 可能数小时不更新。官方 wham/usage 接口返回全通道实时配额，凭据复用
    // Codex CLI 自己维护的 ~/.codex/auth.json（只读，过期由 CLI 刷新）。
    private struct AuthFile: Decodable {
        let tokens: Tokens?
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }
    }

    private struct WhamUsage: Decodable {
        let planType: String?
        let rateLimit: WhamRateLimit?
        let additionalRateLimits: [WhamAdditional]?
        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
        struct WhamAdditional: Decodable {
            let limitName: String?
            let meteredFeature: String?
            let rateLimit: WhamRateLimit?
            enum CodingKeys: String, CodingKey {
                case limitName = "limit_name"
                case meteredFeature = "metered_feature"
                case rateLimit = "rate_limit"
            }
        }
        struct WhamRateLimit: Decodable {
            let primaryWindow: WhamWindow?
            let secondaryWindow: WhamWindow?
            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }
        struct WhamWindow: Decodable {
            let usedPercent: Double?
            // 秒数字段用 Double 解：JSON 数字无类型区分，服务端若返回小数秒
            // （如 18000.0）用 Int 会解码失败，导致整条配额被丢弃
            let limitWindowSeconds: Double?
            let resetAt: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case limitWindowSeconds = "limit_window_seconds"
                case resetAt = "reset_at"
            }
        }
    }

    private static func whamWindow(_ w: WhamUsage.WhamWindow?) -> CodexRateWindow? {
        // secs > 0 兜底：窗口秒数缺失或为 0 时整条窗口无意义，丢弃；
        // 换算分钟取 max(_, 1)，避免极小秒数被整除成 0 分钟
        guard let w, let pct = w.usedPercent, let secs = w.limitWindowSeconds, secs > 0
        else { return nil }
        return CodexRateWindow(usedPercent: pct, windowMinutes: max(Int(secs) / 60, 1),
                               resetsAt: Date(timeIntervalSince1970: w.resetAt ?? 0))
    }

    // 失败（无凭据/过期/网络）返回 nil，调用方回退本地快照
    static func fetchLiveRateLimits(
        enabled: Bool = ConfigStore.shared.codexLiveQuotaEnabled,
        credentialLoader: () -> Data? = {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json")
            return try? Data(contentsOf: url)
        }
    ) async -> [CodexRateLimits]? {
        guard enabled else { return nil }
        guard let authData = credentialLoader(),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: authData),
              let token = auth.tokens?.accessToken, !token.isEmpty else { return nil }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                             timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let acct = auth.tokens?.accountId {
            req.setValue(acct, forHTTPHeaderField: "chatgpt-account-id")
        }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let usage = try? JSONDecoder().decode(WhamUsage.self, from: data) else { return nil }

        let now = Date()
        var out: [CodexRateLimits] = []
        if let rl = usage.rateLimit {
            out.append(CodexRateLimits(
                limitId: "codex", limitName: nil,
                primary: whamWindow(rl.primaryWindow),
                secondary: whamWindow(rl.secondaryWindow),
                planType: usage.planType, asOf: now))
        }
        for extra in usage.additionalRateLimits ?? [] {
            guard let rl = extra.rateLimit else { continue }
            out.append(CodexRateLimits(
                limitId: extra.meteredFeature, limitName: extra.limitName,
                primary: whamWindow(rl.primaryWindow),
                secondary: whamWindow(rl.secondaryWindow),
                planType: usage.planType, asOf: now))
        }
        return out.isEmpty ? nil : out
    }
}

private extension ISO8601DateFormatter {
    // Codex 时间戳带毫秒："2026-06-10T16:13:09.841Z"
    static let codex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
