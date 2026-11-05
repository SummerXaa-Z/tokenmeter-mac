#if DEBUG
import Foundation

// 仅用于显式 UI smoke 参数。所有记录落在 RuntimeEnvironment 的临时目录。
enum PreviewData {
    // 单一渲染时钟：真实今天的中午。与真实今天同日，按天口径的夹具数据
    // 与 DateUtil.today() 消费者始终对齐、永不过期；时分秒固定使同构建
    // 两轮离屏渲染逐字节可比——分钟级时间元素不再随渲染时刻漂移。
    // 每进程求值一次（ui-render 是短命进程，即每次渲染一拍）。
    static let renderNow: Date = {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }()

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
            Calendar.current.date(byAdding: .day, value: -offset, to: renderNow).map(DateUtil.key)
        }
        let claude = ClaudeUsageResult(
            days: dates.enumerated().map { .init(date: $0.element, inputTokens: ($0.offset + 1) * 100_000, messageCount: 1, sessionCount: 1) },
            models: [.init(model: "gpt-5.4", totalTokens: 2_800_000, inputTokens: 2_800_000)],
            projects: [], todayHours: (0..<24).map { .init(hour: $0, totalTokens: $0 == 12 ? 700_000 : 0, deepseekBackendTokens: 0) },
            weekCompare: .empty, skills: [.init(name: "PDF", invocationCount: 30)],
            dayModels: Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, ["gpt-5.4": ModelTokenTally(input: ($0.offset + 1) * 100_000)]) }),
            daySkills: [DateUtil.key(renderNow): ["PDF": 30]])
        let quota = CodexRateLimits(
            limitId: "codex", limitName: nil,
            primary: .init(usedPercent: 40, windowMinutes: 300, resetsAt: renderNow.addingTimeInterval(7_200)),
            secondary: .init(usedPercent: 12, windowMinutes: 10_080, resetsAt: renderNow.addingTimeInterval(432_000)),
            planType: "pro", asOf: renderNow)
        let codex = CodexUsageResult(
            rateLimits: quota, allRateLimits: [quota],
            days: dates.enumerated().map { .init(date: $0.element, inputTokens: ($0.offset + 1) * 200_000, totalTokens: ($0.offset + 1) * 200_000, sessionCount: 1) },
            models: [.init(model: "gpt-5.4", totalTokens: 5_600_000, inputTokens: 5_600_000)],
            projects: [], todayHours: (0..<24).map { .init(hour: $0, totalTokens: $0 == 12 ? 1_400_000 : 0) },
            skills: [.init(name: "pdf", invocationCount: 12), .init(name: "csv", invocationCount: 20)],
            dayModels: Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, ["gpt-5.4": ModelTokenTally(input: ($0.offset + 1) * 200_000)]) }),
            daySkills: [DateUtil.key(renderNow): ["pdf": 12, "csv": 20]])
        state.acceptClaudeCollection(claude)
        state.acceptCodexCollection(codex)
        // accept* 内部把 loadedAt 记成真实时刻，展示层的「数据截至」会随
        // 渲染时刻漂移；统一拨回渲染时钟。
        state.claude.loadedAt = renderNow
        state.codex.loadedAt = renderNow
        // Qwen 页今日卡的分量配色与「未确认显示 —」此前没有离屏覆盖：
        // 补一份合成结果让今日/分时/模型卡都渲染（qwenEnabled 仍为关，
        // 总览与历史快照不受影响）。
        let qwen = QwenCodeUsageResult(
            days: dates.enumerated().map { offset, date in
                .init(
                    date: date,
                    inputTokens: (offset + 1) * 30_000,
                    cachedInputTokens: (offset + 1) * 90_000,
                    outputTokens: (offset + 1) * 15_000,
                    reasoningTokens: (offset + 1) * 6_000,
                    messageCount: offset + 2,
                    sessionCount: 1)
            },
            models: [
                .init(
                    model: "qwen3-coder-plus",
                    inputTokens: 210_000,
                    cachedInputTokens: 630_000,
                    outputTokens: 105_000,
                    reasoningTokens: 42_000),
            ],
            todayHours: (0..<24).map {
                .init(hour: $0, totalTokens: $0 == 12 ? 141_000 : 0)
            },
            dayModels: Dictionary(uniqueKeysWithValues: dates.enumerated().map { offset, date in
                (date, ["qwen3-coder-plus": ModelTokenTally(
                    input: (offset + 1) * 30_000, cached: (offset + 1) * 90_000,
                    output: (offset + 1) * 15_000, reasoning: (offset + 1) * 6_000)])
            }))
        // 直接写缓存而非 acceptQwenCollection：来源开关保持关（总览不出现
        // qwen 行），只有直接托管的 qwen 页消费这份合成结果。
        state.qwen.result = qwen
        state.qwen.loadedAt = renderNow
    }
}
#endif
