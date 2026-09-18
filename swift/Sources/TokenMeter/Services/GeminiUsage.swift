import Foundation

// Gemini CLI 用量采集：纯本地扫描 ~/.gemini/tmp/*/chats 下的 session。
// 当前版本写 JSONL，旧版本写完整 JSON；两种格式都只解码 id/type/timestamp/
// model/tokens 等白名单字段，不把 content、toolCalls 或 thoughts 载入结果。

struct GeminiDayUsage: Equatable, Identifiable {
    let date: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var messageCount = 0
    var sessionCount = 0

    var id: String { date }
    var totalTokens: Int {
        inputTokens + cachedInputTokens + outputTokens + reasoningTokens
    }
    var cacheHitRate: Double? {
        let prompt = inputTokens + cachedInputTokens
        guard prompt > 0 else { return nil }
        return Double(cachedInputTokens) / Double(prompt) * 100
    }
}

struct GeminiModelUsage: Equatable, Identifiable {
    let model: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var messageCount = 0

    var id: String { model }
    var totalTokens: Int {
        inputTokens + cachedInputTokens + outputTokens + reasoningTokens
    }
}

struct GeminiHourUsage: Equatable, Identifiable {
    let hour: Int
    let totalTokens: Int
    var id: Int { hour }
}

struct GeminiUsageResult: Equatable {
    let days: [GeminiDayUsage]
    let models: [GeminiModelUsage]
    let todayHours: [GeminiHourUsage]

    var today: GeminiDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekMessages: Int { days.reduce(0) { $0 + $1.messageCount } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
}

enum GeminiUsageError: LocalizedError {
    case dataUnavailable
    case scanFailed

    var errorDescription: String? {
        switch self {
        case .dataUnavailable: return "未找到 Gemini CLI 本地 session"
        case .scanFailed: return "Gemini CLI 本地用量读取失败"
        }
    }
}

enum GeminiUsage {
    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: sessionsRoot.path)
    }

    private struct Tokens: Decodable {
        let input: Int?
        let output: Int?
        let cached: Int?
        let thoughts: Int?
        let tool: Int?
        let total: Int?
    }

    // JSONL 的 metadata / $set / rewind 行没有 type；解码后自然被过滤。
    private struct MessageLine: Decodable {
        let id: String?
        let timestamp: String?
        let type: String?
        let tokens: Tokens?
        let model: String?
        let sessionId: String?
    }

    private struct LegacySession: Decodable {
        let sessionId: String?
        let messages: [MessageLine]?
    }

    private struct MessageUsage: Equatable {
        let id: String
        let timestamp: Date
        let model: String
        let promptTokens: Int
        let cachedTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int

        var inputTokens: Int { max(promptTokens - cachedTokens, 0) }
    }

    private struct FileSummary {
        let size: UInt64
        let mtime: Date
        let sessionID: String
        let messages: [String: MessageUsage]
    }

    private static var cache: [String: FileSummary] = [:]
    private static let cacheLock = NSLock()

    static func load(
        sessionsRoot: URL = sessionsRoot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> GeminiUsageResult {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            throw GeminiUsageError.dataUnavailable
        }

        let oldestDate = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let oldestDay = calendar.startOfDay(for: oldestDate)
        let files = sessionFiles(in: sessionsRoot, modifiedSince: oldestDay)

        // 旧 .json 迁移到 .jsonl 后可能同时留在 chats 目录。按 sessionId 只取
        // 最新文件，mtime 相同时优先 JSONL，避免完整历史重复计算。
        var sessions: [String: (url: URL, summary: FileSummary)] = [:]
        for file in files {
            let summary = cachedSummary(file)
            guard !summary.messages.isEmpty else { continue }
            if let current = sessions[summary.sessionID] {
                let isNewer = summary.mtime > current.summary.mtime
                let prefersJSONL = summary.mtime == current.summary.mtime
                    && file.pathExtension.lowercased() == "jsonl"
                    && current.url.pathExtension.lowercased() != "jsonl"
                if isNewer || prefersJSONL { sessions[summary.sessionID] = (file, summary) }
            } else {
                sessions[summary.sessionID] = (file, summary)
            }
        }

        var days: [String: GeminiDayUsage] = [:]
        var models: [String: GeminiModelUsage] = [:]
        var sessionsByDay: [String: Set<String>] = [:]
        var todayHours: [Int: Int] = [:]
        let todayKey = localDayKey(now, calendar: calendar)

        for (_, entry) in sessions {
            for message in entry.summary.messages.values {
                guard message.timestamp >= oldestDay, message.timestamp <= now else { continue }
                let dayKey = localDayKey(message.timestamp, calendar: calendar)
                var day = days[dayKey] ?? GeminiDayUsage(date: dayKey)
                day.inputTokens += message.inputTokens
                day.cachedInputTokens += message.cachedTokens
                day.outputTokens += message.outputTokens
                day.reasoningTokens += message.reasoningTokens
                day.messageCount += 1
                days[dayKey] = day
                sessionsByDay[dayKey, default: []].insert(entry.summary.sessionID)
                if dayKey == todayKey {
                    let hour = calendar.component(.hour, from: message.timestamp)
                    todayHours[hour, default: 0] += message.inputTokens
                        + message.cachedTokens + message.outputTokens + message.reasoningTokens
                }

                var model = models[message.model] ?? GeminiModelUsage(model: message.model)
                model.inputTokens += message.inputTokens
                model.cachedInputTokens += message.cachedTokens
                model.outputTokens += message.outputTokens
                model.reasoningTokens += message.reasoningTokens
                model.messageCount += 1
                models[message.model] = model
            }
        }

        let dayRows = (0..<7).map { index -> GeminiDayUsage in
            let date = calendar.date(byAdding: .day, value: index - 6, to: now) ?? now
            let key = localDayKey(date, calendar: calendar)
            var day = days[key] ?? GeminiDayUsage(date: key)
            day.sessionCount = sessionsByDay[key]?.count ?? 0
            return day
        }
        let modelRows = models.values.filter { $0.totalTokens > 0 }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
        let hourRows = (0..<24).map {
            GeminiHourUsage(hour: $0, totalTokens: todayHours[$0] ?? 0)
        }
        return GeminiUsageResult(days: dayRows, models: modelRows, todayHours: hourRows)
    }

    private static func sessionFiles(in root: URL, modifiedSince cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator {
            let ext = file.pathExtension.lowercased()
            guard ext == "jsonl" || ext == "json",
                  file.pathComponents.contains("chats"),
                  let values = try? file.resourceValues(forKeys: Set(keys)),
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

        let summary = file.pathExtension.lowercased() == "json"
            ? scanLegacyJSON(file, size: size, mtime: mtime)
            : scanJSONL(file, size: size, mtime: mtime)
        cacheLock.lock()
        cache[file.path] = summary
        cacheLock.unlock()
        return summary
    }

    private static func scanJSONL(_ file: URL, size: UInt64, mtime: Date) -> FileSummary {
        var sessionID = file.path
        var messages: [String: MessageUsage] = [:]
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return FileSummary(size: size, mtime: mtime, sessionID: sessionID, messages: [:])
        }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        let newline = UInt8(ascii: "\n")
        let chunkSize = 2 * 1024 * 1024
        var carry = Data()
        var reachedEnd = false

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
                let lineData = data[lineStart..<end]
                lineStart = data.index(after: end)
                guard let line = try? decoder.decode(MessageLine.self, from: lineData) else {
                    continue
                }
                if let metadataID = line.sessionId, !metadataID.isEmpty {
                    sessionID = metadataID
                }
                if let usage = messageUsage(line) {
                    // Gemini CLI 更新 tokens/toolCalls 时会再次 append 同一 message id。
                    // 最后一版覆盖前一版，保留真实请求一次而不是按 JSONL 行数累加。
                    messages[usage.id] = usage
                }
            }
        }
        return FileSummary(size: size, mtime: mtime, sessionID: sessionID, messages: messages)
    }

    private static func scanLegacyJSON(_ file: URL, size: UInt64, mtime: Date) -> FileSummary {
        let fallback = FileSummary(
            size: size, mtime: mtime, sessionID: file.path, messages: [:]
        )
        // 旧版完整 JSON 含会话内容，限制单文件 32MB，避免异常文件无限占用内存。
        guard size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let session = try? JSONDecoder().decode(LegacySession.self, from: data)
        else { return fallback }

        var messages: [String: MessageUsage] = [:]
        for line in session.messages ?? [] {
            if let usage = messageUsage(line) { messages[usage.id] = usage }
        }
        return FileSummary(
            size: size,
            mtime: mtime,
            sessionID: session.sessionId ?? file.path,
            messages: messages
        )
    }

    private static func messageUsage(_ line: MessageLine) -> MessageUsage? {
        guard line.type == "gemini",
              let id = line.id, !id.isEmpty,
              let timestampText = line.timestamp,
              let timestamp = parseDate(timestampText)
        else { return nil }

        let tokens = line.tokens
        return MessageUsage(
            id: id,
            timestamp: timestamp,
            model: normalizedModel(line.model),
            promptTokens: nonNegative(tokens?.input),
            cachedTokens: nonNegative(tokens?.cached),
            outputTokens: nonNegative(tokens?.output),
            reasoningTokens: nonNegative(tokens?.thoughts)
        )
    }

    private static func normalizedModel(_ model: String?) -> String {
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
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
