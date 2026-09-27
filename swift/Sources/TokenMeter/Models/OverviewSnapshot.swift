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
    // 固定范围的上期基期金额(今日档比昨日、7 天比前 7 天、30 天比前 30 天);
    // 「全部」没有可比基期,为 nil
    let priorAPIReferenceCost: APIReferenceCostSummary?
    // 所选来源最早有模型明细的一天（截至今天）；nil 表示尚无明细
    let modelCoverageStartDate: String?
    // 所选范围内的工具用量早于模型明细起点：模型维度只覆盖后一段
    let modelCoverageIsPartial: Bool
    // 用户在设置里填写了订阅月费时的回本倍数；未填写为 nil
    let subscriptionValue: SubscriptionValueSummary?
    let trend: [TrendPoint]
    let trendGranularity: UsageTrendGranularity
    let trendTotal: Int
    // 趋势桶键(日=自然日/周=周一/月=月首/小时=当日) → 来源 → API 等价美元：
    // 悬停说明行的金额数据，同价格口径、不随图例隐藏(视图端按可见来源取)
    let apiValueByTrendBucket: [String: [HistorySource: Double]]
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

    /// 范围早于模型明细起点时，模型榜 / Skills 榜 / 会话数 / API 等价共用的口径说明。
    var modelCoverageNote: String? {
        guard modelCoverageIsPartial, let modelCoverageStartDate else { return nil }
        return Self.modelCoverageNote(since: modelCoverageStartDate)
    }

    static func modelCoverageNote(since start: String) -> String {
        "按天明细自 \(Fmt.mmdd(start)) 起留存，更早的用量只计入工具合计。"
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
        modelHistory: [ModelUsageDay] = [],
        subscriptionPlans: [SubscriptionPlan] = [],
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
        // 模型 / Skills / 会话三个维度（模型榜、API 等价参考、输入缓存复用、
        // Skills 榜、会话数）按天明细聚合并跟随所选范围：采集器本次扫描到的
        // 天优先，其余天取本机留存的明细。Cursor 只有订阅周期聚合，不进入。
        let modelSources = selection.sources.filter { $0 != .cursor }
        var liveModels: [HistorySource: [String: [String: ModelTokenTally]]] = [:]
        var liveSkills: [HistorySource: [String: [String: Int]]] = [:]
        var liveSessions: [HistorySource: [String: Int]] = [:]
        liveModels[.claude] = claude?.dayModels
        liveModels[.codex] = codex?.dayModels
        liveModels[.kimi] = kimi?.dayModels
        liveModels[.opencode] = openCode?.dayModels
        liveModels[.gemini] = gemini?.dayModels
        liveModels[.copilot] = copilot?.dayModels
        liveModels[.qwen] = qwen?.dayModels
        liveSkills[.claude] = claude?.daySkills
        liveSkills[.codex] = codex?.daySkills
        liveSkills[.copilot] = copilot?.daySkills
        liveSessions[.claude] = claude?.daySessions
        liveSessions[.codex] = codex?.daySessions
        liveSessions[.kimi] = kimi?.daySessions
        liveSessions[.opencode] = openCode?.daySessions
        liveSessions[.gemini] = gemini?.daySessions
        liveSessions[.copilot] = copilot?.daySessions
        liveSessions[.qwen] = qwen?.daySessions
        let modelDays = Self.mergedDetailDays(
            sources: modelSources,
            liveModels: liveModels,
            liveSkills: liveSkills,
            liveSessions: liveSessions,
            persisted: modelHistory,
            todayKey: todayKey
        )
        let rangeStartKey = Self.rangeStartKey(range, todayKey: todayKey)
        let rangeDates = modelDays.keys.filter { date in
            rangeStartKey.map { date >= $0 } ?? true
        }.sorted()

        var modelSamples: [PersonalUsageRankings.ModelSample] = []
        var costSamples: [APICostSample] = []
        var sourceTallies: [HistorySource: ModelTokenTally] = [:]
        var skillCountBySource: [HistorySource: [String: Int]] = [:]
        var sessionBySource: [HistorySource: Int] = [:]
        for date in rangeDates {
            // 首个价格快照之前的用量按首个快照计价，此后按用量当日生效价
            let pricingDate = max(date, APIReferencePricingCatalog.firstObservedAt)
            let bySource = modelDays[date] ?? [:]
            for source in modelSources {
                guard let detail = bySource[source] else { continue }
                sessionBySource[source, default: 0] += detail.sessions
                for (name, count) in detail.skills {
                    skillCountBySource[source, default: [:]][name, default: 0] += count
                }
                for model in detail.models.keys.sorted() {
                    guard let tally = detail.models[model] else { continue }
                    modelSamples.append(.init(
                        source: source, model: model, totalTokens: tally.total))
                    costSamples.append(.init(
                        model: model, tokens: tally.breakdown,
                        usageDate: pricingDate, source: source))
                    sourceTallies[source, default: .init()] += tally
                }
            }
        }

        profile = PersonalUsageProfile(
            history: history,
            streakHistory: streakHistory,
            enabledSources: selection.sources,
            sessionsBySource: sessionBySource,
            cacheUsage: sourceTallies.mapValues {
                PersonalUsageProfile.CacheUsage(
                    cachedInputTokens: $0.cached, totalInputTokens: $0.promptTokens)
            }
        )
        rankings = PersonalUsageRankings(
            history: history,
            enabledSources: selection.sources,
            modelSamples: modelSamples
        )

        skillRankings = PersonalSkillRankings(
            samples: skillCountBySource.flatMap { source, byName in
                byName.map {
                    PersonalSkillRankings.Sample(
                        source: source, name: $0.key, invocationCount: $0.value)
                }
            },
            enabledSources: selection.sources
        )

        apiReferenceCost = APIReferenceCostSummary(
            samples: costSamples,
            estimator: APIReferencePricingCatalog.estimator,
            referenceDate: APIReferencePricingCatalog.observedAt,
            conversionRates: APIReferencePricingCatalog.conversionRatesToUSD
        )

        // 上期基期:同长度的上一个滚动窗口(今日→昨日、7 天→前 7 天、
        // 30 天→前 30 天),同价格口径取样,供总览 API 等价卡做环比徽标
        if let dayCount = range.fixedDayCount,
           let today = DateUtil.date(from: todayKey),
           let priorEnd = Calendar.current.date(
               byAdding: .day, value: -dayCount, to: today),
           let priorStart = Calendar.current.date(
               byAdding: .day, value: 1 - 2 * dayCount, to: today)
        {
            let startKey = DateUtil.key(priorStart)
            let endKey = DateUtil.key(priorEnd)
            var priorSamples: [APICostSample] = []
            for date in modelDays.keys.sorted() where date >= startKey && date <= endKey {
                let pricingDate = max(date, APIReferencePricingCatalog.firstObservedAt)
                let bySource = modelDays[date] ?? [:]
                for source in modelSources {
                    guard let detail = bySource[source] else { continue }
                    for model in detail.models.keys.sorted() {
                        guard let tally = detail.models[model] else { continue }
                        priorSamples.append(.init(
                            model: model, tokens: tally.breakdown,
                            usageDate: pricingDate, source: source))
                    }
                }
            }
            priorAPIReferenceCost = APIReferenceCostSummary(
                samples: priorSamples,
                estimator: APIReferencePricingCatalog.estimator,
                referenceDate: APIReferencePricingCatalog.observedAt,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD
            )
        } else {
            priorAPIReferenceCost = nil
        }

        let coverageStart = modelDays.keys.min()
        modelCoverageStartDate = coverageStart
        let firstModelSourceUsage = history.first { point in
            modelSources.contains { (point.bySource[$0] ?? 0) > 0 }
        }?.date
        if let coverageStart, let firstModelSourceUsage {
            modelCoverageIsPartial = firstModelSourceUsage < coverageStart
        } else {
            modelCoverageIsPartial = false
        }

        let monthlyFee = SubscriptionPlan.monthlyTotalUSD(subscriptionPlans)
        if monthlyFee > 0, let coverageStart {
            // 订阅费只摊到范围内有模型明细的自然日（含未使用的日子），
            // 不拿金额没覆盖到的天去摊成本。
            let start = max(rangeStartKey ?? coverageStart, coverageStart)
            subscriptionValue = SubscriptionValueSummary(
                monthlyFeeUSD: monthlyFee,
                days: Self.dayCount(from: start, through: todayKey),
                apiValueUSD: apiReferenceCost.total
            )
        } else {
            subscriptionValue = nil
        }

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

        // 悬停金额：逐日按来源重算 API 等价(同价格口径)，再按趋势粒度归桶。
        // 小时粒度桶键即当日，金额整天恒定；缺价模型不计入(与金额卡一致)。
        var valueByBucket: [String: [HistorySource: Double]] = [:]
        let rates = APIReferencePricingCatalog.conversionRatesToUSD
        for (date, bySource) in modelDays {
            let bucket = Self.trendBucket(dateKey: date, granularity: trendGranularity).key
            let pricingDate = max(date, APIReferencePricingCatalog.firstObservedAt)
            for source in modelSources {
                guard let detail = bySource[source] else { continue }
                var daySamples: [APICostSample] = []
                for model in detail.models.keys.sorted() {
                    guard let tally = detail.models[model] else { continue }
                    daySamples.append(.init(
                        model: model, tokens: tally.breakdown,
                        usageDate: pricingDate, source: source))
                }
                guard !daySamples.isEmpty else { continue }
                let summary = APIReferenceCostSummary(
                    samples: daySamples,
                    estimator: APIReferencePricingCatalog.estimator,
                    referenceDate: APIReferencePricingCatalog.observedAt,
                    conversionRates: rates)
                // 缺汇率的币种已被 summary 静默跳过，这里的 total 即可入账的
                // 美元等价；为 0 (全缺价)不建条目，说明行自然不显示金额
                if summary.total > 0 {
                    valueByBucket[bucket, default: [:]][source] =
                        (valueByBucket[bucket]?[source] ?? 0) + summary.total
                }
            }
        }
        apiValueByTrendBucket = valueByBucket
    }

    // 日期 → 来源 → 当天明细（模型 / Skills / 会话）。采集器本次扫描的天
    // 整体覆盖留存明细（同一天不会叠加两份），其余天取留存明细；晚于今天
    // 的日期一律忽略。
    private static func mergedDetailDays(
        sources: [HistorySource],
        liveModels: [HistorySource: [String: [String: ModelTokenTally]]],
        liveSkills: [HistorySource: [String: [String: Int]]],
        liveSessions: [HistorySource: [String: Int]],
        persisted: [ModelUsageDay],
        todayKey: String
    ) -> [String: [HistorySource: SourceDayDetail]] {
        var result: [String: [HistorySource: SourceDayDetail]] = [:]
        for day in persisted where day.date <= todayKey {
            for source in sources {
                guard let detail = day.bySource[source], !detail.isEmpty else { continue }
                result[day.date, default: [:]][source] = detail
            }
        }
        for source in sources {
            let models = liveModels[source] ?? [:]
            let skills = liveSkills[source] ?? [:]
            let sessions = liveSessions[source] ?? [:]
            let dates = Set(models.keys).union(skills.keys).union(sessions.keys)
            for date in dates
            where date <= todayKey && ModelUsageHistoryStore.isDateKey(date) {
                let detail = SourceDayDetail(
                    models: models[date] ?? [:],
                    skills: skills[date] ?? [:],
                    sessions: sessions[date] ?? 0)
                guard !detail.isEmpty else { continue }
                result[date, default: [:]][source] = detail
            }
        }
        return result
    }

    // 固定范围的第一天；“全部”没有下界
    private static func rangeStartKey(_ range: UsageHistoryRange, todayKey: String) -> String? {
        guard let dayCount = range.fixedDayCount,
              let today = DateUtil.date(from: todayKey) else { return nil }
        return DateUtil.key(DateUtil.addDays(today, 1 - dayCount))
    }

    // 含首尾的自然日数
    private static func dayCount(from start: String, through end: String) -> Int {
        guard let first = DateUtil.date(from: start),
              let last = DateUtil.date(from: end),
              first <= last else { return 0 }
        return (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1
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
}
