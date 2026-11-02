import Foundation

// Claude Code 用量解析：纯本地读 ~/.claude/projects/**/*.jsonl（会话 transcript），
// 零网络、零凭据。
//
// 与 Codex 的两个关键差异：
// 1. usage 是该条 assistant 消息的单次值（非累计），不做差分；
//    但同一条消息会随流式输出写多行（model+usage 相同、uuid 不同），
//    必须按 (message.id, requestId) 去重，否则量级翻倍。
// 2. 消息带 model 字段，可按模型分桶（Opus/Sonnet/Haiku/Fable…）。
//
// 文件扫描沿用 CodexUsage 的策略：全树枚举 + mtime 过滤 + 8MB chunk 流式
// 读 + (size, mtime, calendar) 内存缓存。稳定请求/工具调用标识在全扫描范围去重；
// 会话副本和 fork 复制的旧请求只记一次，独立 subagent 的新请求仍保留。

struct ClaudeDayUsage: Equatable, Identifiable {
    let date: String                  // "YYYY-MM-DD"
    var inputTokens: Int = 0          // 非缓存输入
    var cacheCreationTokens: Int = 0  // 缓存写入
    var cacheReadTokens: Int = 0      // 缓存读取
    var outputTokens: Int = 0
    var messageCount: Int = 0         // 去重后的 API 请求数
    var sessionCount: Int = 0
    // 其中模型名为 deepseek-* 的 token，仅作 Claude 内部模型诊断。
    // 这些 token 仍完整归属 Claude 工具，不与 DeepSeek 平台账户口径去重。
    var deepseekBackendTokens: Int = 0

    var id: String { date }
    var totalTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens }
    // 缓存读取占全部输入的比例
    var cacheHitRate: Double? {
        let allInput = inputTokens + cacheCreationTokens + cacheReadTokens
        guard allInput > 0 else { return nil }
        return Double(cacheReadTokens) / Double(allInput) * 100
    }
}

struct ClaudeModelUsage: Equatable, Identifiable {
    let model: String                 // 展示名（去掉 claude- 前缀与日期后缀）
    var totalTokens: Int = 0
    var inputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var outputTokens: Int = 0
    var messageCount: Int = 0
    var id: String { model }
}

struct ClaudeProjectUsage: Equatable, Identifiable {
    let project: String               // cwd 目录名
    var totalTokens: Int = 0
    var messageCount: Int = 0
    var id: String { project }
}

struct ClaudeHourUsage: Equatable, Identifiable {
    let hour: Int                     // 0-23（本地时区）
    let totalTokens: Int
    // 诊断子集：表示本小时 Claude session 里 deepseek-* 模型的 token。
    // 总量与历史入库应使用 totalTokens，不应扣减该字段。
    let deepseekBackendTokens: Int
    var id: Int { hour }
}

struct ClaudeSkillUsage: Equatable, Identifiable {
    let name: String
    var invocationCount: Int
    var id: String { name }
}

// 本周（最近 7 天）vs 上周（8-14 天前）合计；上周为 0 时环比无基期，返回 nil
struct ClaudeWeekCompare: Equatable {
    let thisTotalTokens: Int
    let lastTotalTokens: Int
    let thisOutputTokens: Int
    let lastOutputTokens: Int
    let thisMessageCount: Int
    let lastMessageCount: Int

    var totalChange: Double? { Self.change(thisTotalTokens, lastTotalTokens) }
    var outputChange: Double? { Self.change(thisOutputTokens, lastOutputTokens) }
    var messageChange: Double? { Self.change(thisMessageCount, lastMessageCount) }

    static let empty = ClaudeWeekCompare(thisTotalTokens: 0, lastTotalTokens: 0,
                                         thisOutputTokens: 0, lastOutputTokens: 0,
                                         thisMessageCount: 0, lastMessageCount: 0)

    private static func change(_ cur: Int, _ prev: Int) -> Double? {
        guard prev > 0 else { return nil }
        return (Double(cur) - Double(prev)) / Double(prev) * 100
    }
}

struct ClaudeUsageResult: Equatable {
    let days: [ClaudeDayUsage]        // 最近 7 天，缺失日补零，升序
    let models: [ClaudeModelUsage]    // 7 天窗口内按模型聚合，按量降序
    let projects: [ClaudeProjectUsage] // 7 天窗口内按项目聚合，按量降序
    let todayHours: [ClaudeHourUsage] // 今日 24 小时分布，缺失补零
    let weekCompare: ClaudeWeekCompare // 本周 vs 上周环比
    let skills: [ClaudeSkillUsage]    // 近 7 天，来自原生 Skill tool_use
    // 日期 → 模型 → 互斥五类 Token，落盘为按天模型明细
    var dayModels: [String: [String: ModelTokenTally]] = [:]
    // 日期 → Skill 名 → 调用次数，与 dayModels 同窗口同语义
    var daySkills: [String: [String: Int]] = [:]
    // 有读取失败时聚合可能不完整，不得据此覆盖已保存的完整历史。
    var readError: String? = nil
    var isAuthoritative: Bool { readError == nil }
    var today: ClaudeDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekMessages: Int { days.reduce(0) { $0 + $1.messageCount } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
    // 日期 → 活跃会话数（会话文件在当天有活动即记一次），供按天落盘
    var daySessions: [String: Int] {
        days.reduce(into: [:]) { result, day in
            if day.sessionCount > 0 { result[day.date] = day.sessionCount }
        }
    }
}

enum ClaudeUsage {
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: projectsDir.path)
    }

    // MARK: - JSONL 行解码（只取需要的字段）

    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let sessionId: String?
        let agentId: String?
        let cwd: String?
        let message: Message?
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
            let content: [ContentItem]?
        }
        struct ContentItem: Decodable {
            let type: String?
            let id: String?
            let name: String?
            let input: SkillInput?
        }
        struct SkillInput: Decodable {
            let skill: String?
            let name: String?
        }
        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    // MARK: - 单文件扫描结果与缓存

    private struct Tally: Equatable {
        var input = 0, cacheCreate = 0, cacheRead = 0, output = 0, messages = 0
        var deepseekBackend = 0   // 模型为 deepseek-* 的诊断 token 子集
    }

    private struct HourTally {
        var total = 0
        var deepseekBackend = 0
    }

    private struct FileSummary {
        let size: UInt64
        let mtime: Date
        let calendar: Calendar
        let requests: [RequestUsage]
        let skills: [SkillUsage]
    }

    private struct RequestUsage {
        let timestamp: Date
        let key: String
        let session: String
        let model: String
        let project: String
        let tally: Tally
    }
    private struct SkillUsage {
        let timestamp: Date
        let key: String
        let name: String
    }

    private static var cache: [String: FileSummary] = [:]
    private static let cacheLock = NSLock()

    // MARK: - 入口

    static func load(
        projectsDirectory: URL = projectsDir,
        now: Date = Date(),
        windowDays: Int = 7
    ) -> ClaudeUsageResult {
        let fm = FileManager.default
        let calendar = Calendar.current
        var readError: String?
        let span = max(windowDays, 1)
        var dayMap: [String: ClaudeDayUsage] = [:]
        let window: Set<String> = Set((0..<span).map { DateUtil.key(DateUtil.addDays(now, -$0)) })
        // 上周环比基期仍取 7..14 天；扫描窗按两者较宽者
        let lastWeek: Set<String> = Set((7..<14).map { DateUtil.key(DateUtil.addDays(now, -$0)) })
        for key in window { dayMap[key] = ClaudeDayUsage(date: key) }
        let windowStart = Calendar.current.startOfDay(
            for: DateUtil.addDays(now, 1 - max(span, 14)))

        var modelMap: [String: ClaudeModelUsage] = [:]
        var dayModels: [String: [String: ModelTokenTally]] = [:]
        var daySkills: [String: [String: Int]] = [:]
        var projectMap: [String: ClaudeProjectUsage] = [:]
        var skillMap: [String: Int] = [:]
        var hourMap: [Int: HourTally] = [:]
        var lastTotal = 0, lastOutput = 0, lastMessages = 0
        let todayKey = DateUtil.key(now)
        var files: [(path: String, summary: FileSummary)] = []

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(
            at: projectsDirectory, includingPropertiesForKeys: keys,
            errorHandler: { _, _ in
                readError = readError ?? "本地会话目录读取失败"
                return true
            }
        ) else {
            return ClaudeUsageResult(days: dayMap.values.sorted { $0.date < $1.date },
                                     models: [], projects: [], todayHours: [],
                                     weekCompare: .empty, skills: [],
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
            guard mtime >= windowStart else { continue }
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

        var requests: [String: RequestUsage] = [:]
        var skillRequests: [String: SkillUsage] = [:]
        for file in files.sorted(by: { $0.path < $1.path }) {
            for request in file.summary.requests {
                if let old = requests[request.key] {
                    // 恢复副本可能已完成更完整的流式输出；同一请求只留完整值，
                    // 不是将重复的 usage 相加。时间仍采用原始请求的最早记录。
                    let oldTotal = old.tally.input + old.tally.cacheCreate + old.tally.cacheRead + old.tally.output
                    let newTotal = request.tally.input + request.tally.cacheCreate + request.tally.cacheRead + request.tally.output
                    let complete = newTotal > oldTotal ? request : old
                    requests[request.key] = RequestUsage(
                        timestamp: min(old.timestamp, request.timestamp), key: old.key,
                        session: old.session, model: complete.model,
                        project: complete.project, tally: complete.tally)
                } else {
                    requests[request.key] = request
                }
            }
            for skill in file.summary.skills {
                if let old = skillRequests[skill.key], old.timestamp <= skill.timestamp { continue }
                skillRequests[skill.key] = skill
            }
        }
        var daySessions: [String: Set<String>] = [:]
        for request in requests.values {
            let date = DateUtil.key(request.timestamp)
            let t = request.tally
            // 上周只累计三项合计，不进 days/models/projects。
            if lastWeek.contains(date) {
                lastTotal += t.input + t.cacheCreate + t.cacheRead + t.output
                lastOutput += t.output
                lastMessages += t.messages
            }
            guard window.contains(date) else { continue }
            var d = dayMap[date] ?? ClaudeDayUsage(date: date)
            d.inputTokens += t.input
            d.cacheCreationTokens += t.cacheCreate
            d.cacheReadTokens += t.cacheRead
            d.outputTokens += t.output
            d.messageCount += t.messages
            d.deepseekBackendTokens += t.deepseekBackend
            dayMap[date] = d
            daySessions[date, default: []].insert(request.session)
            let total = t.input + t.cacheCreate + t.cacheRead + t.output
            var m = modelMap[request.model] ?? ClaudeModelUsage(model: request.model)
            m.totalTokens += total
            m.inputTokens += t.input
            m.cacheCreationTokens += t.cacheCreate
            m.cacheReadTokens += t.cacheRead
            m.outputTokens += t.output
            m.messageCount += t.messages
            modelMap[request.model] = m
            dayModels[date, default: [:]][request.model, default: .init()] += ModelTokenTally(
                input: t.input, cached: t.cacheRead, cacheWrite: t.cacheCreate, output: t.output)
            var p = projectMap[request.project] ?? ClaudeProjectUsage(project: request.project)
            p.totalTokens += total
            p.messageCount += t.messages
            projectMap[request.project] = p
            if date == todayKey {
                let hour = calendar.component(.hour, from: request.timestamp)
                var aggregate = hourMap[hour] ?? HourTally()
                aggregate.total += total
                aggregate.deepseekBackend += t.deepseekBackend
                hourMap[hour] = aggregate
            }
        }
        for (date, ids) in daySessions { dayMap[date]?.sessionCount = ids.count }
        for skill in skillRequests.values {
            let date = DateUtil.key(skill.timestamp)
            guard window.contains(date) else { continue }
            skillMap[skill.name, default: 0] += 1
            daySkills[date, default: [:]][skill.name, default: 0] += 1
        }

        let days = dayMap.values.sorted { $0.date < $1.date }
        let models = modelMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let projects = projectMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let todayHours = (0..<24).map { hour in
            let tally = hourMap[hour] ?? HourTally()
            return ClaudeHourUsage(
                hour: hour,
                totalTokens: tally.total,
                deepseekBackendTokens: tally.deepseekBackend
            )
        }
        let compare = ClaudeWeekCompare(
            thisTotalTokens: days.reduce(0) { $0 + $1.totalTokens },
            lastTotalTokens: lastTotal,
            thisOutputTokens: days.reduce(0) { $0 + $1.outputTokens },
            lastOutputTokens: lastOutput,
            thisMessageCount: days.reduce(0) { $0 + $1.messageCount },
            lastMessageCount: lastMessages)
        let skills = skillMap.map { ClaudeSkillUsage(name: $0.key, invocationCount: $0.value) }
            .sorted {
                if $0.invocationCount != $1.invocationCount {
                    return $0.invocationCount > $1.invocationCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        return ClaudeUsageResult(days: days, models: models, projects: projects,
                                 todayHours: todayHours, weekCompare: compare, skills: skills,
                                 dayModels: dayModels.compactMapValues(ModelTokenTally.nonEmpty),
                                 daySkills: daySkills, readError: readError)
    }

    // MARK: - 单文件流式扫描（带缓存）

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

        let usageMarker = Data("\"usage\"".utf8)
        let skillMarker = Data("\"Skill\"".utf8)
        let newline = UInt8(ascii: "\n")
        let chunkSize = 8 * 1024 * 1024
        let decoder = JSONDecoder()

        var requests: [RequestUsage] = []
        var skills: [SkillUsage] = []
        var seenSkillCalls = Set<String>() // tool_use.id 去重，避免流式重复行
        var carry = Data()
        var lineNumber = 0

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
                    carry = data[lineStart...]
                    break
                }
                let line = data[lineStart..<nl]
                lineStart = data.index(after: nl)
                lineNumber += 1
                guard line.range(of: usageMarker) != nil || line.range(of: skillMarker) != nil,
                      let row = try? decoder.decode(Line.self, from: line),
                      row.type == "assistant",
                      let ts = row.timestamp.flatMap({ ISO8601DateFormatter.claude.date(from: $0) })
                else { continue }

                // Claude 原生 Skill 工具提供结构化名称。只保留名称与次数；同一
                // tool_use 在流式 transcript 中重复出现时按 id 去重。
                for item in row.message?.content ?? []
                where item.type == "tool_use" && item.name == "Skill" {
                    guard let name = normalizedSkillName(item.input?.skill ?? item.input?.name)
                    else { continue }
                    let key = item.id.flatMap { $0.isEmpty ? nil : "tool:\($0)" }
                        ?? "file:\(file.path)|\(lineNumber)|\(name)"
                    guard seenSkillCalls.insert(key).inserted else { continue }
                    skills.append(SkillUsage(timestamp: ts, key: key, name: name))
                }

                guard let usage = row.message?.usage else { continue }

                let rawModel = row.message?.model ?? ""
                let isDeepseek = rawModel.hasPrefix("deepseek")
                let msgTotal = (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
                    + (usage.cacheReadInputTokens ?? 0) + (usage.outputTokens ?? 0)
                let stableKey = "\(row.message?.id ?? "")|\(row.requestId ?? "")"
                let key = stableKey == "|" ? "file:\(file.path)|\(lineNumber)" : "request:\(stableKey)"
                // 子代理通常共享父 sessionId，agentId/标准 subagents 文件名保留
                // 独立会话身份；复制出来的父请求本身仍按 request key 合并。
                let agent = row.agentId ?? (file.deletingLastPathComponent().lastPathComponent == "subagents"
                    ? file.deletingPathExtension().lastPathComponent : "")
                let session = row.sessionId.flatMap { $0.isEmpty ? nil : "session:\($0)|\(agent)" }
                    ?? "file:\(file.path)"
                requests.append(RequestUsage(
                    timestamp: ts, key: key, session: session,
                    model: Self.displayModel(row.message?.model), project: Self.displayProject(row.cwd),
                    tally: Tally(input: usage.inputTokens ?? 0,
                                 cacheCreate: usage.cacheCreationInputTokens ?? 0,
                                 cacheRead: usage.cacheReadInputTokens ?? 0,
                                 output: usage.outputTokens ?? 0, messages: 1,
                                 deepseekBackend: isDeepseek ? msgTotal : 0)))
            }
        }
        return FileSummary(size: size, mtime: mtime, calendar: calendar,
                           requests: requests, skills: skills)
    }

    private static func normalizedSkillName(_ value: String?) -> String? {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name.count <= 128,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }

    // cwd 最后一段作为项目名；空值归入 "(其他)"
    private static func displayProject(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "(其他)" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "(其他)" : name
    }

    // "claude-opus-4-8" → "opus-4-8"，"claude-fable-5" → "fable-5"；其他原样
    private static func displayModel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unknown" }
        if raw.hasPrefix("claude-") { return String(raw.dropFirst("claude-".count)) }
        return raw
    }
}

private extension ISO8601DateFormatter {
    // Claude 时间戳带毫秒："2026-06-11T06:35:07.772Z"
    static let claude: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
