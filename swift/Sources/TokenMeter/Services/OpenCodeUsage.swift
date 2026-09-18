import Foundation
import SQLite3

// OpenCode 用量采集：纯本地、只读 ~/.local/share/opencode/opencode.db。
//
// 数据库的 message.data 同时含会话正文和结构化用量；为守住隐私边界，查询只
// 白名单提取 role、模型、五类 token、cost 与时间，不返回 prompt、part 或代码。
// WAL 由 SQLite 只读连接正常合并，OpenCode 运行中也能安全读取最新已提交记录。

struct OpenCodeDayUsage: Equatable, Identifiable {
    let date: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var messageCount = 0
    var sessionCount = 0

    var id: String { date }
    var totalTokens: Int {
        inputTokens + cachedInputTokens + cacheWriteTokens + outputTokens + reasoningTokens
    }
    var cacheHitRate: Double? {
        let totalInput = inputTokens + cachedInputTokens + cacheWriteTokens
        guard totalInput > 0 else { return nil }
        return Double(cachedInputTokens) / Double(totalInput) * 100
    }
}

struct OpenCodeModelUsage: Equatable, Identifiable {
    let model: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var messageCount = 0
    var cost = 0.0

    var id: String { model }
    var totalTokens: Int {
        inputTokens + cachedInputTokens + cacheWriteTokens + outputTokens + reasoningTokens
    }
}

struct OpenCodeHourUsage: Equatable, Identifiable {
    let hour: Int
    let totalTokens: Int
    var id: Int { hour }
}

struct OpenCodeUsageResult: Equatable {
    let days: [OpenCodeDayUsage]
    let models: [OpenCodeModelUsage]
    let todayHours: [OpenCodeHourUsage]

    var today: OpenCodeDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekMessages: Int { days.reduce(0) { $0 + $1.messageCount } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
    var weekCost: Double { models.reduce(0) { $0 + $1.cost } }
}

enum OpenCodeUsageError: LocalizedError {
    case databaseUnavailable
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "未找到 OpenCode 本地数据库"
        case .queryFailed(let detail):
            return "OpenCode 本地用量读取失败：\(detail)"
        }
    }
}

enum OpenCodeUsage {
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    // OpenCode 新版把 role/model/tokens 放在 message.data 顶层；较老版本放在
    // metadata.assistant 下。COALESCE 让同一采集器同时兼容两种结构。
    private static let usageQuery = """
        SELECT
            message.session_id,
            COALESCE(
                json_extract(message.data, '$.time.created'),
                json_extract(message.data, '$.metadata.time.created'),
                message.time_created
            ) AS created_at,
            COALESCE(
                json_extract(message.data, '$.providerID'),
                json_extract(message.data, '$.metadata.assistant.providerID'),
                ''
            ) AS provider_id,
            COALESCE(
                json_extract(message.data, '$.modelID'),
                json_extract(message.data, '$.metadata.assistant.modelID'),
                'unknown'
            ) AS model_id,
            CAST(COALESCE(
                json_extract(message.data, '$.tokens.input'),
                json_extract(message.data, '$.metadata.assistant.tokens.input'),
                0
            ) AS INTEGER) AS input_tokens,
            CAST(COALESCE(
                json_extract(message.data, '$.tokens.cache.read'),
                json_extract(message.data, '$.metadata.assistant.tokens.cache.read'),
                0
            ) AS INTEGER) AS cache_read_tokens,
            CAST(COALESCE(
                json_extract(message.data, '$.tokens.cache.write'),
                json_extract(message.data, '$.metadata.assistant.tokens.cache.write'),
                0
            ) AS INTEGER) AS cache_write_tokens,
            CAST(COALESCE(
                json_extract(message.data, '$.tokens.output'),
                json_extract(message.data, '$.metadata.assistant.tokens.output'),
                0
            ) AS INTEGER) AS output_tokens,
            CAST(COALESCE(
                json_extract(message.data, '$.tokens.reasoning'),
                json_extract(message.data, '$.metadata.assistant.tokens.reasoning'),
                0
            ) AS INTEGER) AS reasoning_tokens,
            CAST(COALESCE(
                json_extract(message.data, '$.cost'),
                json_extract(message.data, '$.metadata.assistant.cost'),
                0
            ) AS REAL) AS cost
        FROM message
        WHERE COALESCE(
                json_extract(message.data, '$.role'),
                json_extract(message.data, '$.metadata.role')
              ) = 'assistant'
          AND COALESCE(
                json_extract(message.data, '$.time.created'),
                json_extract(message.data, '$.metadata.time.created'),
                message.time_created
              ) >= ?
        ORDER BY created_at ASC, message.id ASC
        """

    static func load(
        databaseURL: URL = databaseURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> OpenCodeUsageResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw OpenCodeUsageError.databaseUnavailable
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK,
              let db else {
            throw OpenCodeUsageError.databaseUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, usageQuery, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw OpenCodeUsageError.queryFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }

        let oldestDate = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let oldestDay = calendar.startOfDay(for: oldestDate)
        sqlite3_bind_int64(stmt, 1, Int64(oldestDay.timeIntervalSince1970 * 1_000))

        var days: [String: OpenCodeDayUsage] = [:]
        var models: [String: OpenCodeModelUsage] = [:]
        var sessionsByDay: [String: Set<String>] = [:]
        var todayHours: [Int: Int] = [:]
        let todayKey = localDayKey(now, calendar: calendar)

        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw OpenCodeUsageError.queryFailed(errorMessage(db))
            }

            let sessionID = text(stmt, 0) ?? ""
            let createdMilliseconds = sqlite3_column_int64(stmt, 1)
            guard createdMilliseconds > 0 else { continue }
            let date = Date(timeIntervalSince1970: Double(createdMilliseconds) / 1_000)
            guard date >= oldestDay, date <= now else { continue }
            let dayKey = localDayKey(date, calendar: calendar)

            let provider = text(stmt, 2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let modelID = text(stmt, 3)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            let modelName = provider.isEmpty ? modelID : "\(provider)/\(modelID)"
            let input = nonNegativeInt(stmt, 4)
            let cacheRead = nonNegativeInt(stmt, 5)
            let cacheWrite = nonNegativeInt(stmt, 6)
            let output = nonNegativeInt(stmt, 7)
            let reasoning = nonNegativeInt(stmt, 8)
            let cost = max(sqlite3_column_double(stmt, 9), 0)
            let totalTokens = input + cacheRead + cacheWrite + output + reasoning

            var day = days[dayKey] ?? OpenCodeDayUsage(date: dayKey)
            day.inputTokens += input
            day.cachedInputTokens += cacheRead
            day.cacheWriteTokens += cacheWrite
            day.outputTokens += output
            day.reasoningTokens += reasoning
            day.messageCount += 1
            days[dayKey] = day
            if !sessionID.isEmpty { sessionsByDay[dayKey, default: []].insert(sessionID) }
            if dayKey == todayKey {
                let hour = calendar.component(.hour, from: date)
                todayHours[hour, default: 0] += totalTokens
            }

            var model = models[modelName] ?? OpenCodeModelUsage(model: modelName)
            model.inputTokens += input
            model.cachedInputTokens += cacheRead
            model.cacheWriteTokens += cacheWrite
            model.outputTokens += output
            model.reasoningTokens += reasoning
            model.messageCount += 1
            model.cost += cost
            models[modelName] = model
        }

        let dayRows = (0..<7).map { index -> OpenCodeDayUsage in
            let date = calendar.date(byAdding: .day, value: index - 6, to: now) ?? now
            let key = localDayKey(date, calendar: calendar)
            var day = days[key] ?? OpenCodeDayUsage(date: key)
            day.sessionCount = sessionsByDay[key]?.count ?? 0
            return day
        }
        let modelRows = models.values.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
        let hourRows = (0..<24).map {
            OpenCodeHourUsage(hour: $0, totalTokens: todayHours[$0] ?? 0)
        }
        return OpenCodeUsageResult(days: dayRows, models: modelRows, todayHours: hourRows)
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: value)
    }

    private static func nonNegativeInt(_ stmt: OpaquePointer, _ column: Int32) -> Int {
        let value = sqlite3_column_int64(stmt, column)
        guard value > 0 else { return 0 }
        return value > Int64(Int.max) ? Int.max : Int(value)
    }

    private static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        guard let db, let value = sqlite3_errmsg(db) else { return "unknown SQLite error" }
        return String(cString: value)
    }
}
