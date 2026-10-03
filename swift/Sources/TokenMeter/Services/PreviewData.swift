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
            days: dates.enumerated().map { .init(date: $0.element, inputTokens: ($0.offset + 1) * 100_000, messageCount: 1, sessionCount: 1) },
            models: [.init(model: "gpt-5.4", totalTokens: 2_800_000, inputTokens: 2_800_000)],
            projects: [], todayHours: (0..<24).map { .init(hour: $0, totalTokens: $0 == 12 ? 700_000 : 0, deepseekBackendTokens: 0) },
            weekCompare: .empty, skills: [.init(name: "PDF", invocationCount: 30)],
            dayModels: Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, ["gpt-5.4": ModelTokenTally(input: ($0.offset + 1) * 100_000)]) }),
            daySkills: [DateUtil.today(): ["PDF": 30]])
        let quota = CodexRateLimits(
            limitId: "codex", limitName: nil,
            primary: .init(usedPercent: 40, windowMinutes: 300, resetsAt: Date().addingTimeInterval(7_200)),
            secondary: .init(usedPercent: 12, windowMinutes: 10_080, resetsAt: Date().addingTimeInterval(432_000)),
            planType: "pro", asOf: Date())
        let codex = CodexUsageResult(
            rateLimits: quota, allRateLimits: [quota],
            days: dates.enumerated().map { .init(date: $0.element, inputTokens: ($0.offset + 1) * 200_000, totalTokens: ($0.offset + 1) * 200_000, sessionCount: 1) },
            models: [.init(model: "gpt-5.4", totalTokens: 5_600_000, inputTokens: 5_600_000)],
            projects: [], todayHours: (0..<24).map { .init(hour: $0, totalTokens: $0 == 12 ? 1_400_000 : 0) },
            skills: [.init(name: "pdf", invocationCount: 12), .init(name: "csv", invocationCount: 20)],
            dayModels: Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, ["gpt-5.4": ModelTokenTally(input: ($0.offset + 1) * 200_000)]) }),
            daySkills: [DateUtil.today(): ["pdf": 12, "csv": 20]])
        state.acceptClaudeCollection(claude)
        state.acceptCodexCollection(codex)
    }
}
#endif
