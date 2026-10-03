import Foundation

// 来源级声明集中身份、能力和路径；解析结果类型仍由各采集器保留，不用
// 一个万能结果抹平 Cursor 周期接口与本地逐请求数据之间的差异。
enum SourceCatalog {
    enum Access { case localSessions, authenticatedAccount }
    enum HistoryAuthority { case replaceConfirmedEmpty, retainAbsent }
    enum Capability: Hashable { case dailyUsage, modelDetail, skills, hourlyUsage }

    struct Descriptor: Identifiable {
        let source: HistorySource
        let provider: Provider
        let displayName: String
        let access: Access
        let historyAuthority: HistoryAuthority
        let capabilities: Set<Capability>
        let roots: () -> [URL]
        let isAvailable: () -> Bool
        var id: HistorySource { source }
        var isCodingAgent: Bool { source != .deepseek }

        func isEnabled(in store: ConfigStore) -> Bool {
            switch source {
            case .deepseek: return store.deepseekMonitorEnabled
            case .claude: return store.claudeMonitorEnabled
            case .codex: return store.codexMonitorEnabled
            case .kimi: return store.kimiMonitorEnabled
            case .opencode: return store.opencodeMonitorEnabled
            case .gemini: return store.geminiMonitorEnabled
            case .copilot: return store.copilotMonitorEnabled
            case .qwen: return store.qwenMonitorEnabled
            case .cursor: return store.cursorMonitorEnabled
            }
        }
    }

    static let entries: [Descriptor] = [
        .init(source: .deepseek, provider: .deepseek, displayName: "DeepSeek",
              access: .authenticatedAccount, historyAuthority: .retainAbsent,
              capabilities: [.dailyUsage], roots: { [] }, isAvailable: { true }),
        .init(source: .claude, provider: .claude, displayName: "Claude",
              access: .localSessions, historyAuthority: .replaceConfirmedEmpty,
              capabilities: [.dailyUsage, .modelDetail, .skills, .hourlyUsage],
              roots: { [ClaudeUsage.projectsDir] }, isAvailable: { ClaudeUsage.isAvailable }),
        .init(source: .codex, provider: .codex, displayName: "Codex",
              access: .localSessions, historyAuthority: .retainAbsent,
              capabilities: [.dailyUsage, .modelDetail, .skills, .hourlyUsage],
              roots: { [CodexUsage.sessionsDir] }, isAvailable: { CodexUsage.isAvailable }),
        .init(source: .kimi, provider: .kimi, displayName: "Kimi Code",
              access: .localSessions, historyAuthority: .replaceConfirmedEmpty,
              capabilities: [.dailyUsage, .modelDetail, .hourlyUsage],
              roots: { KimiUsage.defaultHomes }, isAvailable: { KimiUsage.isAvailable }),
        .init(source: .opencode, provider: .opencode, displayName: "OpenCode",
              access: .localSessions, historyAuthority: .retainAbsent,
              capabilities: [.dailyUsage, .modelDetail, .hourlyUsage],
              roots: { [OpenCodeUsage.databaseURL, URL(fileURLWithPath: OpenCodeUsage.databaseURL.path + "-wal")] },
              isAvailable: { OpenCodeUsage.isAvailable }),
        .init(source: .gemini, provider: .gemini, displayName: "Gemini CLI",
              access: .localSessions, historyAuthority: .retainAbsent,
              capabilities: [.dailyUsage, .modelDetail, .hourlyUsage],
              roots: { [GeminiUsage.sessionsRoot] }, isAvailable: { GeminiUsage.isAvailable }),
        .init(source: .copilot, provider: .copilot, displayName: "GitHub Copilot",
              access: .localSessions, historyAuthority: .retainAbsent,
              capabilities: [.dailyUsage, .modelDetail, .skills],
              roots: { [CopilotUsage.sessionsRoot] }, isAvailable: { CopilotUsage.isAvailable }),
        .init(source: .qwen, provider: .qwen, displayName: "Qwen Code",
              access: .localSessions, historyAuthority: .replaceConfirmedEmpty,
              capabilities: [.dailyUsage, .modelDetail, .hourlyUsage],
              roots: { [QwenCodeUsage.usageRecordURL] }, isAvailable: { QwenCodeUsage.isAvailable }),
        .init(source: .cursor, provider: .cursor, displayName: "Cursor",
              access: .authenticatedAccount, historyAuthority: .replaceConfirmedEmpty,
              capabilities: [.dailyUsage], roots: { [CursorUsage.stateDB] },
              isAvailable: { CursorUsage.isAvailable }),
    ]

    static var codingAgentSources: [HistorySource] { entries.filter(\.isCodingAgent).map(\.source) }
    static var localSources: [HistorySource] { entries.filter { $0.access == .localSessions }.map(\.source) }
    static var modelDetailSources: [HistorySource] {
        entries.filter { $0.capabilities.contains(.modelDetail) }.map(\.source)
    }

    static func descriptor(for source: HistorySource) -> Descriptor {
        // HistorySource 的每个 case 必须恰好有一份声明，由一致性测试守住。
        entries.first { $0.source == source }!
    }
    static func source(for provider: Provider) -> HistorySource {
        entries.first { $0.provider == provider }!.source
    }
    static func provider(for source: HistorySource) -> Provider { descriptor(for: source).provider }
}
