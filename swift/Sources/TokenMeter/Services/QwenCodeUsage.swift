import Foundation

// Qwen Code 用量采集：纯本地、只读 ~/.qwen/usage_record.jsonl。
//
// Qwen Code 自身在 Session 结束时把模型级聚合写入这份文件。记录不含对话正文，
// 因此这里不需要打开 projects/**/chats 下的原始会话。官方口径中 inputTokens
// 包含 cachedTokens；TokenMeter 展示时拆成非缓存输入 + 缓存命中，避免重复计算。
// Qwen 当前没有持久化 cache creation，故该维度保持 0，不做推断。

struct QwenCodeDayUsage: Equatable, Identifiable {
    let date: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var messageCount = 0
    var sessionCount = 0

    var id: String { date }
    var totalTokens: Int {
        qwenSaturatedSum(inputTokens, cachedInputTokens, outputTokens, reasoningTokens)
    }
    var cacheHitRate: Double? {
        let prompt = qwenSaturatedSum(inputTokens, cachedInputTokens)
        guard prompt > 0 else { return nil }
        return Double(cachedInputTokens) / Double(prompt) * 100
    }
}

struct QwenCodeModelUsage: Equatable, Identifiable {
    let model: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var messageCount = 0

    var id: String { model }
    var totalTokens: Int {
        qwenSaturatedSum(inputTokens, cachedInputTokens, outputTokens, reasoningTokens)
    }
}

struct QwenCodeHourUsage: Equatable, Identifiable {
    let hour: Int
    let totalTokens: Int
    var id: Int { hour }
}

struct QwenCodeUsageResult: Equatable {
    let days: [QwenCodeDayUsage]
    let models: [QwenCodeModelUsage]
    let todayHours: [QwenCodeHourUsage]

    var today: QwenCodeDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { qwenSaturatedAdd($0, $1.totalTokens) } }
    var weekMessages: Int { days.reduce(0) { qwenSaturatedAdd($0, $1.messageCount) } }
    var weekSessions: Int { days.reduce(0) { qwenSaturatedAdd($0, $1.sessionCount) } }
}

enum QwenCodeUsageError: LocalizedError, Equatable {
    case dataUnavailable

    var errorDescription: String? {
        switch self {
        case .dataUnavailable:
            return "未找到 Qwen Code 本地用量记录"
        }
    }
}

enum QwenCodeUsage {
    static var usageRecordURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen/usage_record.jsonl")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: usageRecordURL.path)
    }

    private struct SessionRecord: Decodable {
        struct ModelRecord: Decodable {
            let requests: Int?
            let inputTokens: Int?
            let outputTokens: Int?
            let cachedTokens: Int?
            let thoughtsTokens: Int?
        }

        let version: Int?
        let sessionId: String?
        let timestamp: Double?
        let models: [String: ModelRecord]?
    }

    private static let chunkSize = 1 * 1024 * 1024
    private static let maximumLineBytes = 4 * 1024 * 1024
    private static let maximumScanBytes: UInt64 = 64 * 1024 * 1024

    static func load(
        usageRecordURL: URL = usageRecordURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> QwenCodeUsageResult {
        guard FileManager.default.fileExists(atPath: usageRecordURL.path) else {
            throw QwenCodeUsageError.dataUnavailable
        }

        let records = scan(usageRecordURL)
        let oldestDate = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let oldestDay = calendar.startOfDay(for: oldestDate)
        let todayKey = localDayKey(now, calendar: calendar)
        var days: [String: QwenCodeDayUsage] = [:]
        var models: [String: QwenCodeModelUsage] = [:]
        var sessionsByDay: [String: Set<String>] = [:]
        var todayHours: [Int: Int] = [:]

        for record in records.values {
            guard record.version == 1,
                  let sessionID = record.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty,
                  let milliseconds = record.timestamp,
                  milliseconds.isFinite,
                  milliseconds > 0
            else { continue }

            let date = Date(timeIntervalSince1970: milliseconds / 1_000)
            guard date >= oldestDay, date <= now else { continue }
            let dayKey = localDayKey(date, calendar: calendar)
            var day = days[dayKey] ?? QwenCodeDayUsage(date: dayKey)

            for (rawName, rawModel) in record.models ?? [:] {
                let modelName = normalizedModel(rawName)
                let prompt = nonNegative(rawModel.inputTokens)
                let cached = min(nonNegative(rawModel.cachedTokens), prompt)
                let input = prompt - cached
                let output = nonNegative(rawModel.outputTokens)
                let reasoning = nonNegative(rawModel.thoughtsTokens)
                let requests = nonNegative(rawModel.requests)
                let total = qwenSaturatedSum(input, cached, output, reasoning)

                day.inputTokens = qwenSaturatedAdd(day.inputTokens, input)
                day.cachedInputTokens = qwenSaturatedAdd(day.cachedInputTokens, cached)
                day.outputTokens = qwenSaturatedAdd(day.outputTokens, output)
                day.reasoningTokens = qwenSaturatedAdd(day.reasoningTokens, reasoning)
                day.messageCount = qwenSaturatedAdd(day.messageCount, requests)

                var model = models[modelName] ?? QwenCodeModelUsage(model: modelName)
                model.inputTokens = qwenSaturatedAdd(model.inputTokens, input)
                model.cachedInputTokens = qwenSaturatedAdd(model.cachedInputTokens, cached)
                model.outputTokens = qwenSaturatedAdd(model.outputTokens, output)
                model.reasoningTokens = qwenSaturatedAdd(model.reasoningTokens, reasoning)
                model.messageCount = qwenSaturatedAdd(model.messageCount, requests)
                models[modelName] = model

                if dayKey == todayKey {
                    let hour = calendar.component(.hour, from: date)
                    todayHours[hour] = qwenSaturatedAdd(todayHours[hour] ?? 0, total)
                }
            }

            days[dayKey] = day
            sessionsByDay[dayKey, default: []].insert(sessionID)
        }

        let dayRows = (0..<7).map { index -> QwenCodeDayUsage in
            let date = calendar.date(byAdding: .day, value: index - 6, to: now) ?? now
            let key = localDayKey(date, calendar: calendar)
            var day = days[key] ?? QwenCodeDayUsage(date: key)
            day.sessionCount = sessionsByDay[key]?.count ?? 0
            return day
        }
        let modelRows = models.values.filter { $0.totalTokens > 0 }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
        let hourRows = (0..<24).map {
            QwenCodeHourUsage(hour: $0, totalTokens: todayHours[$0] ?? 0)
        }
        return QwenCodeUsageResult(days: dayRows, models: modelRows, todayHours: hourRows)
    }

    // 官方 loadUsageHistory 用 sessionId -> record 的 Map 去重，后出现的完整记录覆盖
    // 旧记录。这里保持同一语义，同时支持写入中的非换行 EOF 尾行。
    private static func scan(_ file: URL) -> [String: SessionRecord] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }

        let size = UInt64(max(
            (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
            0
        ))
        let startOffset = size > maximumScanBytes ? size - maximumScanBytes : 0
        if startOffset > 0 { try? handle.seek(toOffset: startOffset) }

        let decoder = JSONDecoder()
        let newline = UInt8(ascii: "\n")
        var carry = Data()
        var records: [String: SessionRecord] = [:]
        var droppingFirstPartialLine = startOffset > 0
        var droppingOversizedLine = false
        var reachedEnd = false

        func consume(_ data: Data) {
            guard !data.isEmpty,
                  data.count <= maximumLineBytes,
                  let record = try? decoder.decode(SessionRecord.self, from: data),
                  let sessionID = record.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty
            else { return }
            records[sessionID] = record
        }

        while !reachedEnd {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            var data: Data
            if chunk.isEmpty {
                guard !carry.isEmpty else { break }
                data = carry
                data.append(newline)
                carry.removeAll(keepingCapacity: false)
                reachedEnd = true
            } else if carry.isEmpty {
                data = chunk
            } else {
                data = carry + chunk
                carry.removeAll(keepingCapacity: false)
            }

            var lineStart = data.startIndex
            while lineStart < data.endIndex {
                guard let end = data[lineStart...].firstIndex(of: newline) else {
                    let remainder = data[lineStart...]
                    if droppingFirstPartialLine || droppingOversizedLine || remainder.count > maximumLineBytes {
                        droppingOversizedLine = droppingOversizedLine || remainder.count > maximumLineBytes
                        carry.removeAll(keepingCapacity: false)
                    } else {
                        carry = Data(remainder)
                    }
                    break
                }

                if droppingFirstPartialLine {
                    droppingFirstPartialLine = false
                } else if droppingOversizedLine {
                    droppingOversizedLine = false
                } else {
                    consume(Data(data[lineStart..<end]))
                }
                lineStart = data.index(after: end)
            }
        }
        return records
    }

    private static func normalizedModel(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "unknown" : value
    }

    private static func nonNegative(_ value: Int?) -> Int { max(value ?? 0, 0) }

    private static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private func qwenSaturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : value
}

private func qwenSaturatedSum(_ values: Int...) -> Int {
    values.reduce(0, qwenSaturatedAdd)
}
