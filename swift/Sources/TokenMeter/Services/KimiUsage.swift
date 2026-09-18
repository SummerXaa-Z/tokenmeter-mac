import Foundation

// Kimi Code 用量采集：纯本地、只读官方 session journal。
//
// 支持两个官方运行目录：
// - standalone CLI：~/.kimi-code
// - Kimi.app 内嵌 runtime：~/Library/Application Support/kimi-desktop/...
//
// wire.jsonl 里同一次模型请求会同时出现增量 `usage.record` 和
// `context.append_loop_event.step.end.usage`。这里只认前者，避免双算；
// JSON 解码白名单也只有 type/time/model/usage，不承载 prompt、回复、工具参数、
// 工作目录或任何凭据。

struct KimiDayUsage: Equatable, Identifiable {
    let date: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheCreationTokens = 0
    var outputTokens = 0
    var messageCount = 0       // 带 usage.record 的模型请求数
    var sessionCount = 0

    var id: String { date }
    var totalTokens: Int {
        kimiSaturatedSum(inputTokens, cachedInputTokens, cacheCreationTokens, outputTokens)
    }
    var cacheHitRate: Double? {
        let allInput = kimiSaturatedSum(inputTokens, cachedInputTokens, cacheCreationTokens)
        guard allInput > 0 else { return nil }
        return Double(cachedInputTokens) / Double(allInput) * 100
    }
}

struct KimiModelUsage: Equatable, Identifiable {
    let model: String
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheCreationTokens = 0
    var outputTokens = 0
    var messageCount = 0

    var id: String { model }
    var totalTokens: Int {
        kimiSaturatedSum(inputTokens, cachedInputTokens, cacheCreationTokens, outputTokens)
    }
}

struct KimiHourUsage: Equatable, Identifiable {
    let hour: Int
    let totalTokens: Int
    var id: Int { hour }
}

struct KimiUsageResult: Equatable {
    let days: [KimiDayUsage]
    let models: [KimiModelUsage]
    let todayHours: [KimiHourUsage]

    var today: KimiDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { kimiSaturatedAdd($0, $1.totalTokens) } }
    var weekMessages: Int { days.reduce(0) { kimiSaturatedAdd($0, $1.messageCount) } }
    var weekSessions: Int { days.reduce(0) { kimiSaturatedAdd($0, $1.sessionCount) } }
}

enum KimiUsageError: LocalizedError, Equatable {
    case dataUnavailable

    var errorDescription: String? {
        "未找到 Kimi Code 本地 session"
    }
}

enum KimiUsage {
    static let maximumHomes = 8
    static let maximumWireFiles = 50_000
    static let maximumLineBytes = 256 * 1024
    private static let maximumChildrenPerDirectory = 20_000
    private static let chunkSize = 1024 * 1024

    static var standaloneHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    static var desktopHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home",
                isDirectory: true
            )
    }

    static var defaultHomes: [URL] { [standaloneHome, desktopHome] }

    static var isAvailable: Bool {
        defaultHomes.contains { isDirectory($0.appendingPathComponent("sessions")) }
    }

    // MARK: - 只解码结构化用量字段

    private struct WireRecord: Decodable {
        let type: String?
        let time: WireTime?
        let model: String?
        let usage: Tokens?
        let usageScope: String?

        enum CodingKeys: String, CodingKey {
            case type, time, model, usage, usageScope
        }
    }

    private struct Tokens: Decodable {
        let inputOther: Int?
        let output: Int?
        let inputCacheRead: Int?
        let inputCacheCreation: Int?
    }

    private struct WireTime: Decodable {
        let date: Date?

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self), number.isFinite {
                // 官方 wire 使用 epoch 毫秒；兼容少数旧 adapter 的 epoch 秒。
                let seconds = abs(number) >= 100_000_000_000 ? number / 1_000 : number
                date = Date(timeIntervalSince1970: seconds)
                return
            }
            guard let string = try? value.decode(String.self) else {
                date = nil
                return
            }
            if let number = Double(string), number.isFinite {
                let seconds = abs(number) >= 100_000_000_000 ? number / 1_000 : number
                date = Date(timeIntervalSince1970: seconds)
                return
            }
            date = parseISO8601(string)
        }
    }

    private struct UsageRecord: Equatable {
        let timestamp: Date
        let model: String
        let input: Int
        let cached: Int
        let cacheCreation: Int
        let output: Int

        var total: Int { kimiSaturatedSum(input, cached, cacheCreation, output) }
    }

    private struct JournalCandidate {
        let file: URL
        let sessionDirectory: URL
        let sessionID: String
        let agentID: String
        let size: UInt64
        let mtime: Date
    }

    private struct SessionCopy {
        let sessionDirectory: URL
        let sessionID: String
        var journals: [(candidate: JournalCandidate, summary: FileSummary)]

        var recordCount: Int {
            journals.reduce(0) { kimiSaturatedAdd($0, $1.summary.records.count) }
        }
        var newestRecord: Date {
            journals.map(\.summary.newestRecord).max() ?? .distantPast
        }
        var newestMtime: Date {
            journals.map(\.candidate.mtime).max() ?? .distantPast
        }
        var totalSize: UInt64 {
            journals.reduce(0) { total, journal in
                let (value, overflow) = total.addingReportingOverflow(journal.candidate.size)
                return overflow ? UInt64.max : value
            }
        }
    }

    private struct FileSummary {
        let size: UInt64
        let mtime: Date
        let records: [UsageRecord]

        var newestRecord: Date {
            records.map(\.timestamp).max() ?? .distantPast
        }
    }

    private static var cache: [String: FileSummary] = [:]
    private static let cacheLock = NSLock()

    static func load(
        homeDirectories: [URL] = defaultHomes,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> KimiUsageResult {
        let homes = uniqueHomes(homeDirectories)
        guard homes.contains(where: { isDirectory($0.appendingPathComponent("sessions")) }) else {
            throw KimiUsageError.dataUnavailable
        }

        let oldestDate = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let oldestDay = calendar.startOfDay(for: oldestDate)
        let candidates = homes
            .flatMap { journalCandidates(in: $0, modifiedSince: oldestDay) }
            .sorted { candidateOrder($0, $1) }
            .prefix(maximumWireFiles)

        // 先把 main/subagent journal 重新组合为一份完整 session。副本去重必须
        // 在 session 层做，不能把同一 session 的不同 agent 互相淘汰。
        var copiesByPath: [String: SessionCopy] = [:]
        for candidate in candidates {
            let summary = cachedSummary(candidate)
            guard !summary.records.isEmpty else { continue }
            let path = candidate.sessionDirectory.path
            if var copy = copiesByPath[path] {
                copy.journals.append((candidate, summary))
                copiesByPath[path] = copy
            } else {
                copiesByPath[path] = SessionCopy(
                    sessionDirectory: candidate.sessionDirectory,
                    sessionID: candidate.sessionID,
                    journals: [(candidate, summary)]
                )
            }
        }

        // 同名 session 可能在 standalone、Kimi.app 或迁移目录留下整份副本。
        // 选择 usage.record 更多（再看更新时间）的一整份，绝不跨副本拼接 agent。
        var selected: [String: SessionCopy] = [:]
        for copy in copiesByPath.values {
            if let current = selected[copy.sessionID] {
                if isMoreComplete(copy, than: current) { selected[copy.sessionID] = copy }
            } else {
                selected[copy.sessionID] = copy
            }
        }

        var days: [String: KimiDayUsage] = [:]
        var models: [String: KimiModelUsage] = [:]
        var sessionsByDay: [String: Set<String>] = [:]
        var todayHours: [Int: Int] = [:]
        let todayKey = localDayKey(now, calendar: calendar)

        for (sessionID, session) in selected {
            for journal in session.journals {
                for record in journal.summary.records {
                    guard record.timestamp >= oldestDay, record.timestamp <= now else { continue }
                    let dayKey = localDayKey(record.timestamp, calendar: calendar)

                    var day = days[dayKey] ?? KimiDayUsage(date: dayKey)
                    day.inputTokens = kimiSaturatedAdd(day.inputTokens, record.input)
                    day.cachedInputTokens = kimiSaturatedAdd(day.cachedInputTokens, record.cached)
                    day.cacheCreationTokens = kimiSaturatedAdd(
                        day.cacheCreationTokens,
                        record.cacheCreation
                    )
                    day.outputTokens = kimiSaturatedAdd(day.outputTokens, record.output)
                    day.messageCount = kimiSaturatedAdd(day.messageCount, 1)
                    days[dayKey] = day
                    sessionsByDay[dayKey, default: []].insert(sessionID)

                    if dayKey == todayKey {
                        let hour = calendar.component(.hour, from: record.timestamp)
                        todayHours[hour] = kimiSaturatedAdd(todayHours[hour] ?? 0, record.total)
                    }

                    var model = models[record.model] ?? KimiModelUsage(model: record.model)
                    model.inputTokens = kimiSaturatedAdd(model.inputTokens, record.input)
                    model.cachedInputTokens = kimiSaturatedAdd(model.cachedInputTokens, record.cached)
                    model.cacheCreationTokens = kimiSaturatedAdd(
                        model.cacheCreationTokens,
                        record.cacheCreation
                    )
                    model.outputTokens = kimiSaturatedAdd(model.outputTokens, record.output)
                    model.messageCount = kimiSaturatedAdd(model.messageCount, 1)
                    models[record.model] = model
                }
            }
        }

        let dayRows = (0..<7).map { index -> KimiDayUsage in
            let date = calendar.date(byAdding: .day, value: index - 6, to: now) ?? now
            let key = localDayKey(date, calendar: calendar)
            var day = days[key] ?? KimiDayUsage(date: key)
            day.sessionCount = sessionsByDay[key]?.count ?? 0
            return day
        }
        let modelRows = models.values.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
        let hourRows = (0..<24).map {
            KimiHourUsage(hour: $0, totalTokens: todayHours[$0] ?? 0)
        }
        return KimiUsageResult(days: dayRows, models: modelRows, todayHours: hourRows)
    }

    // MARK: - 路径发现

    private static func uniqueHomes(_ homes: [URL]) -> [URL] {
        var seen = Set<String>()
        return homes.prefix(maximumHomes).compactMap { home in
            let normalized = home.standardizedFileURL
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
    }

    private static func journalCandidates(in home: URL, modifiedSince cutoff: Date)
        -> [JournalCandidate] {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard isDirectory(sessions) else { return [] }

        var result: [JournalCandidate] = []
        for workspace in childDirectories(at: sessions) {
            for session in childDirectories(at: workspace) {
                let sessionID = session.lastPathComponent
                guard !sessionID.isEmpty else { continue }
                let agents = session.appendingPathComponent("agents", isDirectory: true)
                for agent in childDirectories(at: agents) {
                    let agentID = agent.lastPathComponent
                    guard !agentID.isEmpty else { continue }
                    let file = agent.appendingPathComponent("wire.jsonl")
                    guard let values = try? file.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                    ]), values.isRegularFile == true,
                    values.isSymbolicLink != true,
                    let mtime = values.contentModificationDate,
                    mtime >= cutoff
                    else { continue }

                    result.append(JournalCandidate(
                        file: file,
                        sessionDirectory: session,
                        sessionID: sessionID,
                        agentID: agentID,
                        size: UInt64(max(values.fileSize ?? 0, 0)),
                        mtime: mtime
                    ))
                    if result.count >= maximumWireFiles { return result }
                }
            }
        }
        return result
    }

    private static func childDirectories(at parent: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maximumChildrenPerDirectory)
            .filter {
                guard let values = try? $0.resourceValues(forKeys: Set(keys)) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func candidateOrder(_ lhs: JournalCandidate, _ rhs: JournalCandidate) -> Bool {
        if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return lhs.file.path < rhs.file.path
    }

    private static func isMoreComplete(_ candidate: SessionCopy, than current: SessionCopy) -> Bool {
        if candidate.recordCount != current.recordCount {
            return candidate.recordCount > current.recordCount
        }
        if candidate.newestRecord != current.newestRecord {
            return candidate.newestRecord > current.newestRecord
        }
        if candidate.newestMtime != current.newestMtime {
            return candidate.newestMtime > current.newestMtime
        }
        if candidate.totalSize != current.totalSize { return candidate.totalSize > current.totalSize }
        return candidate.sessionDirectory.path < current.sessionDirectory.path
    }

    // MARK: - 有界 JSONL 扫描

    private static func cachedSummary(_ candidate: JournalCandidate) -> FileSummary {
        cacheLock.lock()
        let hit = cache[candidate.file.path]
        cacheLock.unlock()
        if let hit, hit.size == candidate.size, hit.mtime == candidate.mtime { return hit }

        let summary = scan(candidate.file, size: candidate.size, mtime: candidate.mtime)
        cacheLock.lock()
        cache[candidate.file.path] = summary
        cacheLock.unlock()
        return summary
    }

    private static func scan(_ file: URL, size: UInt64, mtime: Date) -> FileSummary {
        let empty = FileSummary(size: size, mtime: mtime, records: [])
        guard let handle = try? FileHandle(forReadingFrom: file) else { return empty }
        defer { try? handle.close() }

        let marker = Data("usage.record".utf8)
        let decoder = JSONDecoder()
        let newline = UInt8(ascii: "\n")
        var records: [UsageRecord] = []
        var carry = Data()
        var droppingOversizedLine = false

        func consume(_ line: Data) {
            guard line.count <= maximumLineBytes,
                  line.range(of: marker) != nil,
                  let row = try? decoder.decode(WireRecord.self, from: line),
                  row.type == "usage.record",
                  let timestamp = row.time?.date,
                  let usage = row.usage
            else { return }
            records.append(UsageRecord(
                timestamp: timestamp,
                model: normalizedModel(row.model),
                input: nonNegative(usage.inputOther),
                cached: nonNegative(usage.inputCacheRead),
                cacheCreation: nonNegative(usage.inputCacheCreation),
                output: nonNegative(usage.output)
            ))
        }

        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty {
                if !droppingOversizedLine, !carry.isEmpty { consume(carry) }
                break
            }

            let data: Data
            if droppingOversizedLine {
                data = chunk
            } else if carry.isEmpty {
                data = chunk
            } else {
                data = carry + chunk
                carry.removeAll(keepingCapacity: false)
            }

            var lineStart = data.startIndex
            while lineStart < data.endIndex {
                guard let end = data[lineStart...].firstIndex(of: newline) else {
                    if !droppingOversizedLine {
                        let remainder = data[lineStart...]
                        if remainder.count > maximumLineBytes {
                            droppingOversizedLine = true
                            carry.removeAll(keepingCapacity: false)
                        } else {
                            carry = Data(remainder)
                        }
                    }
                    break
                }

                if droppingOversizedLine {
                    droppingOversizedLine = false
                } else {
                    consume(Data(data[lineStart..<end]))
                }
                lineStart = data.index(after: end)
            }
        }
        return FileSummary(size: size, mtime: mtime, records: records)
    }

    private static func normalizedModel(_ value: String?) -> String {
        let model = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty, model.count <= 256,
              model.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return "unknown" }
        return model
    }

    private static func nonNegative(_ value: Int?) -> Int { max(value ?? 0, 0) }

    private static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        if let date = fractionalISO8601.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private func kimiSaturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : value
}

private func kimiSaturatedSum(_ values: Int...) -> Int {
    values.reduce(0, kimiSaturatedAdd)
}
