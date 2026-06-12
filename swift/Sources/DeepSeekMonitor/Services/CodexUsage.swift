import Foundation

// Codex CLI 用量解析：纯本地读 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl，
// 零网络、零凭据。每个 session 文件的最后一条 token_count 事件携带
// 该 session 的累计 token 用量与账号级 rate_limits（5 小时窗 + 周窗使用率）。
// 单文件可达数百 MB，只从尾部分块倒读，绝不全量加载。

struct CodexRateWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

struct CodexRateLimits: Equatable {
    let primary: CodexRateWindow?     // 5 小时窗
    let secondary: CodexRateWindow?   // 周窗（10080 分钟）
    let planType: String?
    let asOf: Date                    // 数据时刻（事件时间戳）
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

struct CodexUsageResult: Equatable {
    let rateLimits: CodexRateLimits?
    let days: [CodexDayUsage]         // 最近 7 天，缺失日补零，升序
    var today: CodexDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
}

enum CodexUsage {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: sessionsDir.path)
    }

    // 解码 token_count 事件需要的字段（其余忽略）
    private struct Event: Decodable {
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let info: Info?
            let rateLimits: RateLimits?
            enum CodingKeys: String, CodingKey {
                case type, info
                case rateLimits = "rate_limits"
            }
        }
        struct Info: Decodable {
            let totalTokenUsage: TokenUsage?
            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
            }
        }
        struct TokenUsage: Decodable {
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
            let primary: Window?
            let secondary: Window?
            let planType: String?
            enum CodingKeys: String, CodingKey {
                case primary, secondary
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

    // 扫最近 7 天目录，聚合每日用量；rate_limits 取 mtime 最新文件里的那条
    static func load() -> CodexUsageResult {
        let fm = FileManager.default
        let now = Date()
        var dayMap: [String: CodexDayUsage] = [:]
        var latestLimits: (mtime: Date, limits: CodexRateLimits)?

        for offset in (0..<7).reversed() {
            let day = DateUtil.addDays(now, -offset)
            let key = DateUtil.key(day)
            dayMap[key] = CodexDayUsage(date: key)

            let parts = key.split(separator: "-")
            let dir = sessionsDir
                .appendingPathComponent(String(parts[0]))
                .appendingPathComponent(String(parts[1]))
                .appendingPathComponent(String(parts[2]))
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let event = lastTokenCountEvent(in: file) else { continue }
                if let usage = event.payload?.info?.totalTokenUsage {
                    var d = dayMap[key] ?? CodexDayUsage(date: key)
                    d.inputTokens += usage.inputTokens ?? 0
                    d.cachedInputTokens += usage.cachedInputTokens ?? 0
                    d.outputTokens += usage.outputTokens ?? 0
                    d.reasoningTokens += usage.reasoningOutputTokens ?? 0
                    d.totalTokens += usage.totalTokens ?? 0
                    d.sessionCount += 1
                    dayMap[key] = d
                }
                if let rl = event.payload?.rateLimits {
                    let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                    if latestLimits == nil || mtime > latestLimits!.mtime {
                        let asOf = event.timestamp.flatMap { ISO8601DateFormatter.codex.date(from: $0) } ?? mtime
                        latestLimits = (mtime, CodexRateLimits(
                            primary: rl.primary.flatMap(window),
                            secondary: rl.secondary.flatMap(window),
                            planType: rl.planType,
                            asOf: asOf))
                    }
                }
            }
        }

        let days = dayMap.values.sorted { $0.date < $1.date }
        return CodexUsageResult(rateLimits: latestLimits?.limits, days: days)
    }

    private static func window(_ w: Event.Window) -> CodexRateWindow? {
        guard let pct = w.usedPercent, let minutes = w.windowMinutes else { return nil }
        let resets = Date(timeIntervalSince1970: w.resetsAt ?? 0)
        return CodexRateWindow(usedPercent: pct, windowMinutes: minutes, resetsAt: resets)
    }

    // 从文件尾部分块倒读，找最后一条 token_count 事件。
    // 尾部 256KB 通常够（token_count 每轮都发）；遇到超大工具输出再扩到 2MB。
    private static func lastTokenCountEvent(in file: URL) -> Event? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        for chunkSize in [UInt64(256 * 1024), UInt64(2 * 1024 * 1024)] {
            let offset = size > chunkSize ? size - chunkSize : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
            if let event = parseLastTokenCount(data) { return event }
            if offset == 0 { break }   // 已读到文件头，没有就是没有
        }
        return nil
    }

    private static func parseLastTokenCount(_ data: Data) -> Event? {
        let marker = Data("\"token_count\"".utf8)
        let newline = UInt8(ascii: "\n")
        var lineEnd = data.endIndex
        var idx = data.endIndex
        let decoder = JSONDecoder()
        // 从后往前按行扫，第一条含 token_count 的合法 JSON 即结果
        while idx > data.startIndex {
            idx = data[..<lineEnd].lastIndex(of: newline).map { data.index(after: $0) } ?? data.startIndex
            let line = data[idx..<lineEnd]
            if line.range(of: marker) != nil,
               let event = try? decoder.decode(Event.self, from: line),
               event.payload?.type == "token_count" {
                return event
            }
            if idx == data.startIndex { break }
            lineEnd = data.index(before: idx)
        }
        return nil
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
