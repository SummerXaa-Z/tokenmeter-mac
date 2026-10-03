#if DEBUG
import Foundation

// 仅用于显式 UI smoke 参数。所有记录落在 RuntimeEnvironment 的临时目录。
enum PreviewData {
    @MainActor
    static func seed(_ state: AppState) {
        guard RuntimeEnvironment.isPreview else { return }
        state.deepseekEnabled = false
        state.kimiEnabled = false
        state.opencodeEnabled = false
        state.geminiEnabled = false
        state.copilotEnabled = false
        state.qwenEnabled = false
        state.cursorEnabled = false
        let dates = (0..<7).reversed().compactMap { offset in
            Calendar.current.date(byAdding: .day, value: -offset, to: Date()).map(DateUtil.key)
        }
        let claude = ClaudeUsageResult(
            days: dates.enumerated().map { .init(date: $0.element, inputTokens: ($0.offset + 1) * 100_000) },
            models: [], projects: [], todayHours: [], weekCompare: .empty, skills: [],
            dayModels: Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, ["gpt-5.4": ModelTokenTally(input: ($0.offset + 1) * 100_000)]) }),
            daySkills: [DateUtil.today(): ["PDF": 30]])
        let codex = CodexUsageResult(
            rateLimits: nil, allRateLimits: [],
            days: dates.enumerated().map { .init(date: $0.element, totalTokens: ($0.offset + 1) * 200_000) },
            models: [], projects: [], todayHours: [], skills: [],
            dayModels: Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, ["gpt-5.4": ModelTokenTally(input: ($0.offset + 1) * 200_000)]) }),
            daySkills: [DateUtil.today(): ["pdf": 12, "csv": 20]])
        state.acceptClaudeCollection(claude)
        state.acceptCodexCollection(codex)
    }
}
#endif
