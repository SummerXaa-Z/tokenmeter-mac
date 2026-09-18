import Foundation

// 每个纯本地 Agent 采集器实现同一份最小协议。Output 保留具体类型，让各工具
// 能表达原生差异；注册表通过类型擦除统一拿 source、名称、路径和可用性。
protocol LocalUsageCollector {
    associatedtype Output

    static var source: HistorySource { get }
    static var displayName: String { get }
    static var dataURL: URL { get }
    static var isAvailable: Bool { get }
    static func collect(now: Date) throws -> Output
}

struct LocalUsageCollectorDescriptor: Identifiable {
    let source: HistorySource
    let displayName: String
    let dataPath: URL
    let isAvailable: () -> Bool

    var id: HistorySource { source }

    init<C: LocalUsageCollector>(_ collector: C.Type) {
        source = collector.source
        displayName = collector.displayName
        dataPath = collector.dataURL
        isAvailable = { collector.isAvailable }
    }
}

extension ClaudeUsage: LocalUsageCollector {
    static let source = HistorySource.claude
    static let displayName = "Claude"
    static var dataURL: URL { projectsDir }
    static func collect(now: Date) throws -> ClaudeUsageResult { load(now: now) }
}

extension CodexUsage: LocalUsageCollector {
    static let source = HistorySource.codex
    static let displayName = "Codex"
    static var dataURL: URL { sessionsDir }
    static func collect(now: Date) throws -> CodexUsageResult { load(now: now) }
}

extension KimiUsage: LocalUsageCollector {
    static let source = HistorySource.kimi
    static let displayName = "Kimi Code"
    static var dataURL: URL {
        defaultHomes.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("sessions", isDirectory: true).path
            )
        } ?? standaloneHome
    }
    static func collect(now: Date) throws -> KimiUsageResult { try load(now: now) }
}

extension OpenCodeUsage: LocalUsageCollector {
    static let source = HistorySource.opencode
    static let displayName = "OpenCode"
    static var dataURL: URL { databaseURL }
    static func collect(now: Date) throws -> OpenCodeUsageResult { try load(now: now) }
}

extension GeminiUsage: LocalUsageCollector {
    static let source = HistorySource.gemini
    static let displayName = "Gemini CLI"
    static var dataURL: URL { sessionsRoot }
    static func collect(now: Date) throws -> GeminiUsageResult { try load(now: now) }
}

extension CopilotUsage: LocalUsageCollector {
    static let source = HistorySource.copilot
    static let displayName = "GitHub Copilot"
    static var dataURL: URL { sessionsRoot }
    static func collect(now: Date) throws -> CopilotUsageResult { try load(now: now) }
}

extension QwenCodeUsage: LocalUsageCollector {
    static let source = HistorySource.qwen
    static let displayName = "Qwen Code"
    static var dataURL: URL { usageRecordURL }
    static func collect(now: Date) throws -> QwenCodeUsageResult { try load(now: now) }
}

enum LocalUsageCollectorRegistry {
    static let collectors: [LocalUsageCollectorDescriptor] = [
        .init(ClaudeUsage.self),
        .init(CodexUsage.self),
        .init(KimiUsage.self),
        .init(OpenCodeUsage.self),
        .init(GeminiUsage.self),
        .init(CopilotUsage.self),
        .init(QwenCodeUsage.self),
    ]

    static func collector(for source: HistorySource) -> LocalUsageCollectorDescriptor? {
        collectors.first { $0.source == source }
    }

    static func displayName(for source: HistorySource) -> String {
        switch source {
        case .deepseek: return "DeepSeek"
        case .cursor: return "Cursor"
        case .claude, .codex, .kimi, .opencode, .gemini, .copilot, .qwen:
            return collector(for: source)?.displayName ?? source.rawValue
        }
    }
}
