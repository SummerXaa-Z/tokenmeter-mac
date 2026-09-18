import Foundation

// GitHub Copilot CLI 用量采集：纯本地扫描 ~/.copilot/session-state/*/events.jsonl。
//
// Copilot 把逐请求 assistant.usage 标成 ephemeral，不写入磁盘；会话结束时会把
// 累计 modelMetrics、代码变更等写进 session.shutdown。因此这里按每个 session
// 最新的 shutdown 统计，并把整段会话归到结束日。只解码事件类型、链路、模型、
// Token、消息/Skill 名和代码行数；content、路径、工具参数、代码正文均不会进入结果。

struct CopilotDayUsage: Equatable, Identifiable {
    let date: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var requestCount = 0
    var messageCount = 0
    var sessionCount = 0
    var skillCount = 0
    var linesAdded = 0
    var linesRemoved = 0

    var id: String { date }
    var totalTokens: Int {
        inputTokens + cachedInputTokens + cacheWriteTokens + outputTokens + reasoningTokens
    }
    var cacheHitRate: Double? {
        let prompt = inputTokens + cachedInputTokens + cacheWriteTokens
        guard prompt > 0 else { return nil }
        return Double(cachedInputTokens) / Double(prompt) * 100
    }
}

struct CopilotModelUsage: Equatable, Identifiable {
    let model: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var requestCount = 0

    var id: String { model }
    var totalTokens: Int {
        inputTokens + cachedInputTokens + cacheWriteTokens + outputTokens + reasoningTokens
    }
}

struct CopilotSkillUsage: Equatable, Identifiable {
    let name: String
    var invocationCount: Int
    var id: String { name }
}

struct CopilotUsageResult: Equatable {
    let days: [CopilotDayUsage]
    let models: [CopilotModelUsage]
    let skills: [CopilotSkillUsage]

    var today: CopilotDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekMessages: Int { days.reduce(0) { $0 + $1.messageCount } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
    var weekSkills: Int { days.reduce(0) { $0 + $1.skillCount } }
    var weekLinesAdded: Int { days.reduce(0) { $0 + $1.linesAdded } }
    var weekLinesRemoved: Int { days.reduce(0) { $0 + $1.linesRemoved } }
}

enum CopilotUsageError: LocalizedError {
    case dataUnavailable
    case scanFailed

    var errorDescription: String? {
        switch self {
        case .dataUnavailable: return "未找到 GitHub Copilot CLI 本地 session"
        case .scanFailed: return "GitHub Copilot CLI 本地用量读取失败"
        }
    }
}

enum CopilotUsage {
    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: sessionsRoot.path)
    }

    private struct EventLine: Decodable {
        let id: String?
        let timestamp: String?
        let parentId: String?
        let type: String?
        let data: EventData?
    }

    private struct EventData: Decodable {
        let modelMetrics: [String: ModelMetric]?
        let codeChanges: CodeChanges?
        let name: String?
    }

    private struct ModelMetric: Decodable {
        let requests: Requests?
        let usage: TokenUsage?
        let tokenDetails: [String: TokenDetail]?
    }

    private struct TokenDetail: Decodable {
        let tokenCount: Int?
    }

    private struct Requests: Decodable {
        let count: Int?
    }

    private struct TokenUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let reasoningTokens: Int?
    }

    private struct CodeChanges: Decodable {
        let linesAdded: Int?
        let linesRemoved: Int?
    }

    private struct ShutdownSnapshot {
        let id: String
        let timestamp: Date
        let parentID: String?
        let modelMetrics: [String: ModelMetric]
        let codeChanges: CodeChanges
    }

    private struct FileSummary {
        let size: UInt64
        let mtime: Date
        let shutdown: ShutdownSnapshot?
        let messageCount: Int
        let skillNames: [String]
    }

    private static var cache: [String: FileSummary] = [:]
    private static let cacheLock = NSLock()

    static func load(
        sessionsRoot: URL = sessionsRoot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> CopilotUsageResult {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            throw CopilotUsageError.dataUnavailable
        }

        let oldestDate = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let oldestDay = calendar.startOfDay(for: oldestDate)
        let files = sessionFiles(in: sessionsRoot, modifiedSince: oldestDay)

        var days: [String: CopilotDayUsage] = [:]
        var models: [String: CopilotModelUsage] = [:]
        var skills: [String: Int] = [:]

        for file in files {
            let summary = cachedSummary(file)
            guard let shutdown = summary.shutdown,
                  shutdown.timestamp >= oldestDay,
                  shutdown.timestamp <= now
            else { continue }

            let dayKey = localDayKey(shutdown.timestamp, calendar: calendar)
            var day = days[dayKey] ?? CopilotDayUsage(date: dayKey)
            day.messageCount += summary.messageCount
            day.sessionCount += 1
            day.skillCount += summary.skillNames.count
            day.linesAdded += nonNegative(shutdown.codeChanges.linesAdded)
            day.linesRemoved += nonNegative(shutdown.codeChanges.linesRemoved)

            for (name, metric) in shutdown.modelMetrics {
                let normalizedName = normalizedModel(name)
                let usage = metric.usage
                let cacheRead = nonNegative(usage?.cacheReadTokens)
                let cacheWrite = nonNegative(usage?.cacheWriteTokens)
                let reasoning = nonNegative(usage?.reasoningTokens)
                // Copilot 官方 /usage 的 inputTokens 包含 cache read/write，reasoning
                // 也是 outputTokens 的子集。拆成互斥的 Kaboo 五类，保证总量仍等于
                // 官方 input + output，不因展示细分而重复计算。
                let rawInput = nonNegative(usage?.inputTokens)
                let rawOutput = nonNegative(usage?.outputTokens)
                let input = metric.tokenDetails?["input"]?.tokenCount.map { nonNegative($0) }
                    ?? max(rawInput - cacheRead - cacheWrite, 0)
                let output = max(rawOutput - reasoning, 0)
                let requests = nonNegative(metric.requests?.count)

                day.inputTokens += input
                day.cachedInputTokens += cacheRead
                day.cacheWriteTokens += cacheWrite
                day.outputTokens += output
                day.reasoningTokens += reasoning
                day.requestCount += requests

                var model = models[normalizedName] ?? CopilotModelUsage(model: normalizedName)
                model.inputTokens += input
                model.cachedInputTokens += cacheRead
                model.cacheWriteTokens += cacheWrite
                model.outputTokens += output
                model.reasoningTokens += reasoning
                model.requestCount += requests
                models[normalizedName] = model
            }
            days[dayKey] = day
            for name in summary.skillNames { skills[name, default: 0] += 1 }
        }

        let dayRows = (0..<7).map { index -> CopilotDayUsage in
            let date = calendar.date(byAdding: .day, value: index - 6, to: now) ?? now
            let key = localDayKey(date, calendar: calendar)
            return days[key] ?? CopilotDayUsage(date: key)
        }
        let modelRows = models.values.filter { $0.totalTokens > 0 }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
        let skillRows = skills.map { CopilotSkillUsage(name: $0.key, invocationCount: $0.value) }
            .sorted {
                if $0.invocationCount != $1.invocationCount {
                    return $0.invocationCount > $1.invocationCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        return CopilotUsageResult(days: dayRows, models: modelRows, skills: skillRows)
    }

    private static func sessionFiles(in root: URL, modifiedSince cutoff: Date) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator {
            guard file.lastPathComponent == "events.jsonl",
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff
            else { continue }
            files.append(file)
        }
        return files
    }

    private static func cachedSummary(_ file: URL) -> FileSummary {
        let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(max(attrs?.fileSize ?? 0, 0))
        let mtime = attrs?.contentModificationDate ?? .distantPast

        cacheLock.lock()
        let hit = cache[file.path]
        cacheLock.unlock()
        if let hit, hit.size == size, hit.mtime == mtime { return hit }

        let summary = scan(file, size: size, mtime: mtime)
        cacheLock.lock()
        cache[file.path] = summary
        cacheLock.unlock()
        return summary
    }

    private static func scan(_ file: URL, size: UInt64, mtime: Date) -> FileSummary {
        let empty = FileSummary(
            size: size, mtime: mtime, shutdown: nil, messageCount: 0, skillNames: []
        )
        guard let handle = try? FileHandle(forReadingFrom: file) else { return empty }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        let newline = UInt8(ascii: "\n")
        let chunkSize = 2 * 1024 * 1024
        var carry = Data()
        var reachedEnd = false
        var events: [String: EventLine] = [:]
        var shutdowns: [ShutdownSnapshot] = []

        func consume(_ data: Data) {
            guard !data.isEmpty,
                  let event = try? decoder.decode(EventLine.self, from: data),
                  let id = event.id, !id.isEmpty
            else { return }
            events[id] = event
            guard event.type == "session.shutdown",
                  let timestampText = event.timestamp,
                  let timestamp = parseDate(timestampText),
                  let metrics = event.data?.modelMetrics,
                  let changes = event.data?.codeChanges
            else { return }
            shutdowns.append(ShutdownSnapshot(
                id: id,
                timestamp: timestamp,
                parentID: event.parentId,
                modelMetrics: metrics,
                codeChanges: changes
            ))
        }

        while !reachedEnd {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            var data: Data
            if chunk.isEmpty {
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
                guard let end = data[lineStart...].firstIndex(of: newline) else {
                    carry = data[lineStart...]
                    break
                }
                consume(Data(data[lineStart..<end]))
                lineStart = data.index(after: end)
            }
        }

        guard let latest = shutdowns.max(by: { $0.timestamp < $1.timestamp }) else {
            return empty
        }

        // parentId 是当前可见 session 的链。只沿最新 shutdown 回溯，避免 rewind
        // 后仍留在文件中的旧分支消息与 Skill 被重复计数。
        var activeIDs: Set<String> = [latest.id]
        var cursor = latest.parentID
        while let id = cursor, activeIDs.insert(id).inserted, let event = events[id] {
            cursor = event.parentId
        }

        var messageCount = 0
        var skillNames: [String] = []
        for id in activeIDs {
            guard let event = events[id] else { continue }
            if event.type == "user.message" || event.type == "assistant.message" {
                messageCount += 1
            } else if event.type == "skill.invoked" {
                let value = event.data?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty { skillNames.append(value) }
            }
        }

        return FileSummary(
            size: size,
            mtime: mtime,
            shutdown: latest,
            messageCount: messageCount,
            skillNames: skillNames
        )
    }

    private static func normalizedModel(_ value: String) -> String {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "unknown" : model
    }

    private static func nonNegative(_ value: Int?) -> Int { max(value ?? 0, 0) }

    private static func parseDate(_ value: String) -> Date? {
        if let date = fractionalISO8601.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }
}
