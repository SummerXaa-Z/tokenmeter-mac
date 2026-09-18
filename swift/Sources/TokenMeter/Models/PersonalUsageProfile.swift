import Foundation

// 本地个人 AI 使用画像。只消费已经聚合的历史/用量数字，不读取原始会话内容，
// 也不产生任何网络上报。所有输入都按当前启用来源过滤。
struct PersonalUsageProfile: Equatable {
    struct CacheUsage: Equatable {
        let cachedInputTokens: Int
        let totalInputTokens: Int
    }

    let activeDays: Int
    let currentStreak: Int
    let primarySource: HistorySource?
    let primaryShare: Double?
    let usedSourceCount: Int
    let weeklySessions: Int
    let cachedInputTokens: Int
    let totalInputTokens: Int

    var nonCachedInputTokens: Int { max(totalInputTokens - cachedInputTokens, 0) }
    var cacheHitRate: Double? {
        guard totalInputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(totalInputTokens)
    }

    var badges: [String] {
        var result: [String] = []
        if currentStreak >= 7 { result.append("连续创作") }
        else if activeDays >= 10 { result.append("稳定使用") }

        if usedSourceCount >= 3 { result.append("多工具协作") }
        else if let primaryShare, primaryShare >= 0.8 { result.append("专注主力") }

        if let cacheHitRate, cacheHitRate >= 0.8 { result.append("高缓存复用") }
        return result
    }

    init(
        history: [HistoryStore.DayPoint],
        streakHistory: [HistoryStore.DayPoint]? = nil,
        enabledSources: [HistorySource],
        weeklySessions: [HistorySource: Int],
        cacheUsage: [HistorySource: CacheUsage]
    ) {
        let selected = Set(enabledSources)
        let codingSources = HistorySource.codingAgents.filter(selected.contains)

        func total(_ point: HistoryStore.DayPoint) -> Int {
            codingSources.reduce(0) { $0 + (point.bySource[$1] ?? 0) }
        }

        activeDays = history.reduce(0) { $0 + (total($1) > 0 ? 1 : 0) }
        // 当天尚未开始使用时保留截至昨天的连续记录；只有连续两个空白日
        // 才真正中断，避免每天早上画像先无意义地归零。
        let streakPoints = streakHistory ?? history
        var streak = 0
        var skippedCurrentDay = false
        for point in streakPoints.reversed() {
            if total(point) > 0 {
                streak += 1
            } else if streak == 0, !skippedCurrentDay {
                skippedCurrentDay = true
            } else {
                break
            }
        }
        currentStreak = streak

        var totals: [HistorySource: Int] = [:]
        for source in codingSources {
            totals[source] = history.reduce(0) { $0 + ($1.bySource[source] ?? 0) }
        }
        usedSourceCount = totals.values.filter { $0 > 0 }.count

        var primary: HistorySource?
        var primaryTokens = 0
        for source in codingSources {
            let tokens = totals[source] ?? 0
            if tokens > primaryTokens {
                primary = source
                primaryTokens = tokens
            }
        }
        primarySource = primary
        let allTokens = totals.values.reduce(0, +)
        primaryShare = allTokens > 0 ? Double(primaryTokens) / Double(allTokens) : nil

        self.weeklySessions = codingSources.reduce(0) {
            $0 + max(weeklySessions[$1] ?? 0, 0)
        }
        cachedInputTokens = codingSources.reduce(0) {
            $0 + max(cacheUsage[$1]?.cachedInputTokens ?? 0, 0)
        }
        totalInputTokens = codingSources.reduce(0) {
            $0 + max(cacheUsage[$1]?.totalInputTokens ?? 0, 0)
        }
    }
}
