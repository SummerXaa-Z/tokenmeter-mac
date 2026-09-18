import Foundation

// Coding 总览只展示当前启用的 Coding Agent；DeepSeek 平台历史仍完整保留，
// 但不会进入 Token、画像或排行聚合。
struct OverviewSourceSelection: Equatable {
    let sources: [HistorySource]

    init(sources: [HistorySource]) {
        let selected = Set(sources)
        self.sources = HistorySource.codingAgents.filter(selected.contains)
    }

    init(
        deepseek _: Bool,
        claude: Bool,
        codex: Bool,
        kimi: Bool = false,
        opencode: Bool,
        gemini: Bool,
        copilot: Bool,
        qwen: Bool = false,
        cursor: Bool
    ) {
        self.init(sources: [
            (claude, .claude),
            (codex, .codex),
            (kimi, .kimi),
            (opencode, .opencode),
            (gemini, .gemini),
            (copilot, .copilot),
            (qwen, .qwen),
            (cursor, .cursor),
        ].compactMap { enabled, source in enabled ? source : nil })
    }

    func contains(_ source: HistorySource) -> Bool {
        sources.contains(source)
    }

    func value(_ value: Int, for source: HistorySource) -> Int {
        contains(source) ? value : 0
    }

    func total(_ values: [HistorySource: Int]) -> Int {
        sources.reduce(0) { $0 + (values[$1] ?? 0) }
    }
}
