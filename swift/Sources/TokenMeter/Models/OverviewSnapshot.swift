import Foundation

// 总览的纯数据快照：把来源归属、画像、排行、费用和趋势计算从 SwiftUI
// 渲染层移出。输入与输出都只有本地聚合数字，便于单元测试，也避免卡片各自
// 重复理解来源口径。
struct OverviewSnapshot: Equatable {
    struct TrendPoint: Equatable, Identifiable {
        let date: String
        let label: String
        let hour: Int?
        let source: HistorySource
        let tokens: Int
        var id: String { "\(date)|\(source.rawValue)" }
    }

    let selection: OverviewSourceSelection
    let todayBySource: [HistorySource: Int]
    let todayTotal: Int
    let periodBySource: [HistorySource: Int]
    let periodTotal: Int
    let historyStartDate: String?
    let availableHistoryDays: Int
    let profile: PersonalUsageProfile
    let rankings: PersonalUsageRankings
    let skillRankings: PersonalSkillRankings
    let apiReferenceCost: APIReferenceCostSummary
    let trend: [TrendPoint]
    let trendGranularity: UsageTrendGranularity
    let trendTotal: Int
    let hourlyUnattributedSources: [HistorySource]
    let deepSeekPlatformTokens: Int
    let deepSeekPlatformCost: Double?
    let deepSeekPlatformHistoryStartDate: String?
    let deepSeekPlatformAvailableHistoryDays: Int

    /// 首页工具明细只展示所选范围内实际产生过用量的 Coding Agent。
    /// 设置开关和历史本身不受影响，切换范围后会按该范围重新出现。
    var nonzeroPeriodSources: [HistorySource] {
        selection.sources.filter { (periodBySource[$0] ?? 0) > 0 }
    }

    init(
        selection: OverviewSourceSelection,
        range: UsageHistoryRange,
        history: [HistoryStore.DayPoint],
        streakHistory: [HistoryStore.DayPoint],
        deepSeek: UsageResult?,
        claude: ClaudeUsageResult?,
        codex: CodexUsageResult?,
        kimi: KimiUsageResult? = nil,
        openCode: OpenCodeUsageResult?,
        gemini: GeminiUsageResult?,
        copilot: CopilotUsageResult?,
        qwen: QwenCodeUsageResult? = nil,
        cursor: CursorUsageResult?,
        todayKey: String = DateUtil.today()
    ) {
        self.selection = selection

        // DeepSeek 是平台/API 账户，不是 Coding Agent 工具。它的消费在
        // 独立平台卡展示，不参与下面任何 Coding 合计、画像或排行。
        let recordedPlatformTokens = history.reduce(0) {
            $0 + ($1.bySource[.deepseek] ?? 0)
        }
        let recordedPlatformCost = history.reduce(0.0) {
            $0 + $1.cost(for: .deepseek)
        }
        if range == .day, let deepSeek {
            let liveDay = deepSeek.days.first { $0.date == todayKey }
            deepSeekPlatformTokens = liveDay?.totalTokens ?? 0
            let liveCost = liveDay?.totalCost ?? 0
            deepSeekPlatformCost = liveCost > 0 ? liveCost : nil
        } else {
            deepSeekPlatformTokens = recordedPlatformTokens
            deepSeekPlatformCost = recordedPlatformCost > 0 ? recordedPlatformCost : nil
        }
        if let startIndex = streakHistory.firstIndex(where: {
            ($0.bySource[.deepseek] ?? 0) > 0 || $0.cost(for: .deepseek) > 0
        }) {
            deepSeekPlatformHistoryStartDate = streakHistory[startIndex].date
            deepSeekPlatformAvailableHistoryDays = streakHistory.count - startIndex
        } else if deepSeekPlatformTokens > 0 || deepSeekPlatformCost != nil {
            deepSeekPlatformHistoryStartDate = todayKey
            deepSeekPlatformAvailableHistoryDays = 1
        } else {
            deepSeekPlatformHistoryStartDate = nil
            deepSeekPlatformAvailableHistoryDays = 0
        }

        let claudeToday = selection.value(claude?.today?.totalTokens ?? 0, for: .claude)
        let recordedToday = history.first { $0.date == todayKey }?.bySource ?? [:]
        func liveToday(_ source: HistorySource) -> Int? {
            guard selection.contains(source) else { return 0 }
            switch source {
            case .deepseek:
                return 0
            case .claude:
                guard claude != nil else { return nil }
                return claudeToday
            case .codex:
                return codex.map { $0.today?.totalTokens ?? 0 }
            case .kimi:
                return kimi.map { $0.today?.totalTokens ?? 0 }
            case .opencode:
                return openCode.map { $0.today?.totalTokens ?? 0 }
            case .gemini:
                return gemini.map { $0.today?.totalTokens ?? 0 }
            case .copilot:
                return copilot.map { $0.today?.totalTokens ?? 0 }
            case .qwen:
                return qwen.map { $0.today?.totalTokens ?? 0 }
            case .cursor:
                return cursor?.todayTokens
            }
        }
        let sourceTotals = Dictionary(uniqueKeysWithValues: HistorySource.allCases.map { source in
            let fallback = selection.value(recordedToday[source] ?? 0, for: source)
            return (source, liveToday(source) ?? fallback)
        })
        todayBySource = sourceTotals
        todayTotal = selection.sources.reduce(0) { $0 + (sourceTotals[$1] ?? 0) }
        let computedPeriodBySource = Dictionary(uniqueKeysWithValues: selection.sources.map { source in
            let recorded = history.reduce(0) { $0 + ($1.bySource[source] ?? 0) }
            // 单日视图只要真源已成功加载，就采用精确实时值（允许从旧毛值
            // 下降到较小值或 0）；真源缺席/今日子查询失败才回退历史。
            let tokens = range == .day ? (sourceTotals[source] ?? recorded) : recorded
            return (source, tokens)
        })
        periodBySource = computedPeriodBySource
        periodTotal = computedPeriodBySource.values.reduce(0, +)
        if let startIndex = streakHistory.firstIndex(where: {
            selection.total($0.bySource) > 0
        }) {
            historyStartDate = streakHistory[startIndex].date
            availableHistoryDays = streakHistory.count - startIndex
        } else if todayTotal > 0 {
            historyStartDate = todayKey
            availableHistoryDays = 1
        } else {
            historyStartDate = nil
            availableHistoryDays = 0
        }
        var weeklySessions: [HistorySource: Int] = [:]
        var cacheUsage: [HistorySource: PersonalUsageProfile.CacheUsage] = [:]
        if selection.contains(.claude), let claude {
            weeklySessions[.claude] = claude.weekSessions
            cacheUsage[.claude] = .init(
                cachedInputTokens: claude.days.reduce(0) { $0 + $1.cacheReadTokens },
                totalInputTokens: claude.days.reduce(0) {
                    $0 + $1.inputTokens + $1.cacheCreationTokens + $1.cacheReadTokens
                }
            )
        }
        if selection.contains(.codex), let codex {
            weeklySessions[.codex] = codex.weekSessions
            cacheUsage[.codex] = .init(
                cachedInputTokens: codex.days.reduce(0) { $0 + $1.cachedInputTokens },
                totalInputTokens: codex.days.reduce(0) { $0 + $1.inputTokens }
            )
        }
        if selection.contains(.kimi), let kimi {
            weeklySessions[.kimi] = kimi.weekSessions
            cacheUsage[.kimi] = .init(
                cachedInputTokens: kimi.days.reduce(0) { $0 + $1.cachedInputTokens },
                totalInputTokens: kimi.days.reduce(0) {
                    $0 + $1.inputTokens + $1.cachedInputTokens + $1.cacheCreationTokens
                }
            )
        }
        if selection.contains(.opencode), let openCode {
            weeklySessions[.opencode] = openCode.weekSessions
            cacheUsage[.opencode] = .init(
                cachedInputTokens: openCode.days.reduce(0) { $0 + $1.cachedInputTokens },
                totalInputTokens: openCode.days.reduce(0) {
                    $0 + $1.inputTokens + $1.cachedInputTokens + $1.cacheWriteTokens
                }
            )
        }
        if selection.contains(.gemini), let gemini {
            weeklySessions[.gemini] = gemini.weekSessions
            cacheUsage[.gemini] = .init(
                cachedInputTokens: gemini.days.reduce(0) { $0 + $1.cachedInputTokens },
                totalInputTokens: gemini.days.reduce(0) {
                    $0 + $1.inputTokens + $1.cachedInputTokens
                }
            )
        }
        if selection.contains(.copilot), let copilot {
            weeklySessions[.copilot] = copilot.weekSessions
            cacheUsage[.copilot] = .init(
                cachedInputTokens: copilot.days.reduce(0) { $0 + $1.cachedInputTokens },
                totalInputTokens: copilot.days.reduce(0) {
                    $0 + $1.inputTokens + $1.cachedInputTokens + $1.cacheWriteTokens
                }
            )
        }
        if selection.contains(.qwen), let qwen {
            weeklySessions[.qwen] = qwen.weekSessions
            cacheUsage[.qwen] = .init(
                cachedInputTokens: qwen.days.reduce(0) { $0 + $1.cachedInputTokens },
                totalInputTokens: qwen.days.reduce(0) {
                    $0 + $1.inputTokens + $1.cachedInputTokens
                }
            )
        }
        profile = PersonalUsageProfile(
            history: history,
            streakHistory: streakHistory,
            enabledSources: selection.sources,
            weeklySessions: weeklySessions,
            cacheUsage: cacheUsage
        )

        var modelSamples: [PersonalUsageRankings.ModelSample] = []
        if selection.contains(.claude), let claude {
            modelSamples += claude.models.map {
                .init(source: .claude, model: $0.model, totalTokens: $0.totalTokens)
            }
        }
        if selection.contains(.codex), let codex {
            modelSamples += codex.models.map {
                .init(source: .codex, model: $0.model, totalTokens: $0.totalTokens)
            }
        }
        if selection.contains(.kimi), let kimi {
            modelSamples += kimi.models.map {
                .init(source: .kimi, model: $0.model, totalTokens: $0.totalTokens)
            }
        }
        if selection.contains(.opencode), let openCode {
            modelSamples += openCode.models.map {
                .init(source: .opencode, model: $0.model, totalTokens: $0.totalTokens)
            }
        }
        if selection.contains(.gemini), let gemini {
            modelSamples += gemini.models.map {
                .init(source: .gemini, model: $0.model, totalTokens: $0.totalTokens)
            }
        }
        if selection.contains(.copilot), let copilot {
            modelSamples += copilot.models.map {
                .init(source: .copilot, model: $0.model, totalTokens: $0.totalTokens)
            }
        }
        if selection.contains(.qwen), let qwen {
            modelSamples += qwen.models.map {
                .init(source: .qwen, model: $0.model, totalTokens: $0.totalTokens)
            }
        }
        rankings = PersonalUsageRankings(
            history: history,
            enabledSources: selection.sources,
            modelSamples: modelSamples
        )

        var skillSamples: [PersonalSkillRankings.Sample] = []
        if selection.contains(.claude), let claude {
            skillSamples += claude.skills.map {
                .init(source: .claude, name: $0.name, invocationCount: $0.invocationCount)
            }
        }
        if selection.contains(.codex), let codex {
            skillSamples += codex.skills.map {
                .init(source: .codex, name: $0.name, invocationCount: $0.invocationCount)
            }
        }
        if selection.contains(.copilot), let copilot {
            skillSamples += copilot.skills.map {
                .init(source: .copilot, name: $0.name, invocationCount: $0.invocationCount)
            }
        }
        skillRankings = PersonalSkillRankings(
            samples: skillSamples,
            enabledSources: selection.sources
        )

        let costSamples = Self.costSamples(
            selection: selection,
            claude: claude,
            codex: codex,
            kimi: kimi,
            openCode: openCode,
            gemini: gemini,
            copilot: copilot,
            qwen: qwen
        )
        apiReferenceCost = APIReferenceCostSummary(
            samples: costSamples,
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD
        )

        trendGranularity = range.trendGranularity(
            historyDayCount: range == .all ? availableHistoryDays : history.count
        )
        let computedTrend: [TrendPoint]
        let computedUnattributedSources: [HistorySource]
        if trendGranularity == .hour {
            let hourly = Self.hourlyUsage(
                selection: selection,
                claude: claude,
                codex: codex,
                kimi: kimi,
                openCode: openCode,
                gemini: gemini,
                qwen: qwen
            )
            computedTrend = Self.makeHourlyTrend(
                todayKey: todayKey,
                selection: selection,
                hourly: hourly
            )
            let hourlyTotals = Dictionary(uniqueKeysWithValues: hourly.map { source, values in
                (source, values.values.reduce(0, +))
            })
            computedUnattributedSources = selection.sources.filter { source in
                let daily = computedPeriodBySource[source] ?? 0
                guard daily > 0 else { return false }
                return hourlyTotals[source] != daily
            }
        } else {
            computedTrend = Self.makeTrend(
                history: history,
                selection: selection,
                granularity: trendGranularity,
                range: range,
                todayKey: todayKey
            )
            computedUnattributedSources = []
        }
        trend = computedTrend
        hourlyUnattributedSources = computedUnattributedSources
        trendTotal = computedTrend.reduce(0) { $0 + $1.tokens }
    }

    private static func hourlyUsage(
        selection: OverviewSourceSelection,
        claude: ClaudeUsageResult?,
        codex: CodexUsageResult?,
        kimi: KimiUsageResult?,
        openCode: OpenCodeUsageResult?,
        gemini: GeminiUsageResult?,
        qwen: QwenCodeUsageResult?
    ) -> [HistorySource: [Int: Int]] {
        var result: [HistorySource: [Int: Int]] = [:]
        if selection.contains(.claude), let claude {
            result[.claude] = Dictionary(uniqueKeysWithValues: claude.todayHours.map {
                ($0.hour, max($0.totalTokens, 0))
            })
        }
        if selection.contains(.codex), let codex {
            result[.codex] = Dictionary(uniqueKeysWithValues: codex.todayHours.map {
                ($0.hour, max($0.totalTokens, 0))
            })
        }
        if selection.contains(.kimi), let kimi {
            result[.kimi] = Dictionary(uniqueKeysWithValues: kimi.todayHours.map {
                ($0.hour, max($0.totalTokens, 0))
            })
        }
        if selection.contains(.opencode), let openCode {
            result[.opencode] = Dictionary(uniqueKeysWithValues: openCode.todayHours.map {
                ($0.hour, max($0.totalTokens, 0))
            })
        }
        if selection.contains(.gemini), let gemini {
            result[.gemini] = Dictionary(uniqueKeysWithValues: gemini.todayHours.map {
                ($0.hour, max($0.totalTokens, 0))
            })
        }
        if selection.contains(.qwen), let qwen {
            result[.qwen] = Dictionary(uniqueKeysWithValues: qwen.todayHours.map {
                ($0.hour, max($0.totalTokens, 0))
            })
        }
        return result
    }

    private static func makeHourlyTrend(
        todayKey: String,
        selection: OverviewSourceSelection,
        hourly: [HistorySource: [Int: Int]]
    ) -> [TrendPoint] {
        (0..<24).flatMap { hour in
            selection.sources.compactMap { source in
                guard let values = hourly[source] else { return nil }
                return TrendPoint(
                    date: String(format: "%@T%02d", todayKey, hour),
                    label: String(format: "%02d:00", hour),
                    hour: hour,
                    source: source,
                    tokens: max(values[hour] ?? 0, 0)
                )
            }
        }
    }

    private static func makeTrend(
        history: [HistoryStore.DayPoint],
        selection: OverviewSourceSelection,
        granularity: UsageTrendGranularity,
        range: UsageHistoryRange,
        todayKey: String
    ) -> [TrendPoint] {
        var order: [String] = []
        var seen: Set<String> = []
        var labels: [String: String] = [:]
        var totals: [String: [HistorySource: Int]] = [:]

        // 固定范围先建立完整自然日骨架；即使本机历史尚未积满，7D/30D 的
        // 中间 0 日也不会从横轴消失。“全部”则沿用本机历史的连续日期。
        let skeletonDates: [String]
        if let dayCount = range.fixedDayCount,
           let today = DateUtil.date(from: todayKey) {
            skeletonDates = (0..<dayCount).map { index in
                DateUtil.key(DateUtil.addDays(today, index - dayCount + 1))
            }
        } else if let firstKey = history.first(where: {
            selection.total($0.bySource) > 0
        })?.date,
                  let first = DateUtil.date(from: firstKey),
                  let last = DateUtil.date(from: todayKey) {
            let count = max(
                (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1,
                1
            )
            skeletonDates = (0..<count).map {
                DateUtil.key(DateUtil.addDays(first, $0))
            }
        } else {
            skeletonDates = []
        }
        for date in skeletonDates {
            let bucket = trendBucket(dateKey: date, granularity: granularity)
            if seen.insert(bucket.key).inserted { order.append(bucket.key) }
            labels[bucket.key] = bucket.label
        }

        for point in history {
            let bucket = trendBucket(dateKey: point.date, granularity: granularity)
            // 容错：若调用方传入固定窗口外的点，不让它偷偷扩宽可视范围。
            guard seen.contains(bucket.key) else { continue }
            for source in selection.sources {
                let tokens = max(point.bySource[source] ?? 0, 0)
                guard tokens > 0 else { continue }
                totals[bucket.key, default: [:]][source, default: 0] += tokens
            }
        }

        return order.flatMap { key in
            selection.sources.map { source in
                return TrendPoint(
                    date: key,
                    label: labels[key] ?? key,
                    hour: nil,
                    source: source,
                    tokens: totals[key]?[source] ?? 0
                )
            }
        }
    }

    private static func trendBucket(
        dateKey: String,
        granularity: UsageTrendGranularity
    ) -> (key: String, label: String) {
        guard let date = DateUtil.date(from: dateKey) else {
            return (dateKey, Fmt.mmdd(dateKey))
        }
        switch granularity {
        case .hour:
            return (dateKey, Fmt.mmdd(dateKey))
        case .day:
            return (dateKey, Fmt.mmdd(dateKey))
        case .week:
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = Calendar.current.timeZone
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            let key = DateUtil.key(start)
            return (key, "\(Fmt.mmdd(key))周")
        case .month:
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            let start = Calendar.current.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: 1
            )) ?? date
            let key = DateUtil.key(start)
            return (key, Fmt.ym(key))
        }
    }

    private static func costSamples(
        selection: OverviewSourceSelection,
        claude: ClaudeUsageResult?,
        codex: CodexUsageResult?,
        kimi: KimiUsageResult?,
        openCode: OpenCodeUsageResult?,
        gemini: GeminiUsageResult?,
        copilot: CopilotUsageResult?,
        qwen: QwenCodeUsageResult?
    ) -> [APICostSample] {
        var samples: [APICostSample] = []
        if selection.contains(.claude), let claude {
            for model in claude.models {
                samples.append(.init(model: model.model, tokens: .init(
                    newInputTokens: model.inputTokens,
                    cachedInputTokens: model.cacheReadTokens,
                    cacheCreationTokens: model.cacheCreationTokens,
                    outputTokens: model.outputTokens,
                    reasoningOutputTokens: 0
                )))
            }
        }
        if selection.contains(.codex), let codex {
            samples += codex.models.map { model in
                .init(model: model.model, tokens: .init(
                    newInputTokens: max(model.inputTokens - model.cachedInputTokens, 0),
                    cachedInputTokens: model.cachedInputTokens,
                    cacheCreationTokens: 0,
                    outputTokens: model.outputTokens,
                    reasoningOutputTokens: model.reasoningTokens
                ))
            }
        }
        if selection.contains(.kimi), let kimi {
            samples += kimi.models.map { model in
                .init(model: model.model, tokens: .init(
                    newInputTokens: model.inputTokens,
                    cachedInputTokens: model.cachedInputTokens,
                    cacheCreationTokens: model.cacheCreationTokens,
                    outputTokens: model.outputTokens,
                    reasoningOutputTokens: 0
                ))
            }
        }
        if selection.contains(.opencode), let openCode {
            samples += openCode.models.map { model in
                .init(model: model.model, tokens: .init(
                    newInputTokens: model.inputTokens,
                    cachedInputTokens: model.cachedInputTokens,
                    cacheCreationTokens: model.cacheWriteTokens,
                    outputTokens: model.outputTokens,
                    reasoningOutputTokens: model.reasoningTokens
                ))
            }
        }
        if selection.contains(.gemini), let gemini {
            samples += gemini.models.map { model in
                .init(model: model.model, tokens: .init(
                    newInputTokens: model.inputTokens,
                    cachedInputTokens: model.cachedInputTokens,
                    cacheCreationTokens: 0,
                    outputTokens: model.outputTokens,
                    reasoningOutputTokens: model.reasoningTokens
                ))
            }
        }
        if selection.contains(.copilot), let copilot {
            samples += copilot.models.map { model in
                .init(model: model.model, tokens: .init(
                    newInputTokens: model.inputTokens,
                    cachedInputTokens: model.cachedInputTokens,
                    cacheCreationTokens: model.cacheWriteTokens,
                    outputTokens: max(model.outputTokens - model.reasoningTokens, 0),
                    reasoningOutputTokens: model.reasoningTokens
                ))
            }
        }
        if selection.contains(.qwen), let qwen {
            samples += qwen.models.map { model in
                .init(model: model.model, tokens: .init(
                    newInputTokens: model.inputTokens,
                    cachedInputTokens: model.cachedInputTokens,
                    cacheCreationTokens: 0,
                    outputTokens: model.outputTokens,
                    reasoningOutputTokens: model.reasoningTokens
                ))
            }
        }
        return samples
    }
}
