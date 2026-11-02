import Foundation

// One in-memory overlay for all dashboard consumers. Saving a successful scan may
// fail independently; charts must still use the same scan as model costs/rankings.
// This never writes history and never invents a day from an undated result.
struct LiveUsageHistory: Equatable {
    let daily: [HistoryStore.DayPoint]
    let models: [ModelUsageDay]

    init(
        daily persistedDaily: [HistoryStore.DayPoint],
        models persistedModels: [ModelUsageDay],
        claude: ClaudeUsageResult? = nil, codex: CodexUsageResult? = nil,
        kimi: KimiUsageResult? = nil, openCode: OpenCodeUsageResult? = nil,
        gemini: GeminiUsageResult? = nil, copilot: CopilotUsageResult? = nil,
        qwen: QwenCodeUsageResult? = nil, cursor: CursorUsageResult? = nil,
        todayKey: String = DateUtil.today()
    ) {
        var points = Dictionary(persistedDaily.filter { valid($0.date, through: todayKey) }
            .map { ($0.date, $0) }, uniquingKeysWith: { _, newer in newer })
        var details = Dictionary(persistedModels.filter { valid($0.date, through: todayKey) }
            .map { ($0.date, $0.bySource) }, uniquingKeysWith: { _, newer in newer })

        func apply(
            _ source: HistorySource, totals: [(String, Int)],
            models: [String: [String: ModelTokenTally]],
            skills: [String: [String: Int]] = [:], sessions: [String: Int] = [:]
        ) {
            var accepted = Set<String>()
            for (date, tokens) in totals where valid(date, through: todayKey) {
                // Missing old local files must not erase retained past history.
                // An explicit zero for today, or an authoritative source, is real zero.
                guard tokens > 0 || date == todayKey
                    || SourceCatalog.descriptor(for: source).historyAuthority == .replaceConfirmedEmpty
                else { continue }
                var point = points[date] ?? .init(date: date, bySource: [:], cost: 0)
                point.bySource[source] = max(tokens, 0)
                points[date] = point
                accepted.insert(date)
            }
            let dates = accepted.union(models.keys).union(skills.keys).union(sessions.keys)
            for date in dates where valid(date, through: todayKey) {
                let detail = SourceDayDetail(
                    models: models[date] ?? [:], skills: skills[date] ?? [:],
                    sessions: sessions[date] ?? 0)
                if detail.isEmpty {
                    if accepted.contains(date) { details[date]?.removeValue(forKey: source) }
                } else {
                    details[date, default: [:]][source] = detail
                }
            }
        }
        if let claude, claude.isAuthoritative {
            apply(.claude, totals: claude.days.map { ($0.date, $0.totalTokens) },
                  models: claude.dayModels, skills: claude.daySkills, sessions: claude.daySessions)
        }
        if let codex, codex.isAuthoritative {
            apply(.codex, totals: codex.days.map { ($0.date, $0.totalTokens) },
                  models: codex.dayModels, skills: codex.daySkills, sessions: codex.daySessions)
        }
        if let kimi {
            apply(.kimi, totals: kimi.days.map { ($0.date, $0.totalTokens) },
                  models: kimi.dayModels, sessions: kimi.daySessions)
        }
        if let openCode {
            apply(.opencode, totals: openCode.days.map { ($0.date, $0.totalTokens) },
                  models: openCode.dayModels, sessions: openCode.daySessions)
        }
        if let gemini {
            apply(.gemini, totals: gemini.days.map { ($0.date, $0.totalTokens) },
                  models: gemini.dayModels, sessions: gemini.daySessions)
        }
        if let copilot {
            apply(.copilot, totals: copilot.days.map { ($0.date, $0.totalTokens) },
                  models: copilot.dayModels, skills: copilot.daySkills, sessions: copilot.daySessions)
        }
        if let qwen {
            apply(.qwen, totals: qwen.days.map { ($0.date, $0.totalTokens) },
                  models: qwen.dayModels, sessions: qwen.daySessions)
        }
        if let tokens = cursor?.dailyTokens(on: todayKey) {
            apply(.cursor, totals: [(todayKey, tokens)], models: [:])
        }
        // Keep zero days between observations; do not extend ALL to parser padding
        // before the first actual record.
        let first = points.values.filter { $0.total > 0 || $0.cost > 0 }.map(\.date).min()
            ?? persistedDaily.filter { valid($0.date, through: todayKey) }.map(\.date).min()
        if let first, let start = DateUtil.date(from: first), let end = DateUtil.date(from: todayKey) {
            let count = max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
            daily = (0...count).map {
                let date = DateUtil.key(DateUtil.addDays(start, $0))
                return points[date] ?? .init(date: date, bySource: [:], cost: 0)
            }
        } else {
            daily = points.values.sorted { $0.date < $1.date }
        }
        self.models = details.keys.sorted().compactMap { date in
            let bySource = details[date] ?? [:]
            return bySource.isEmpty ? nil : ModelUsageDay(date: date, bySource: bySource)
        }
    }
}

private func valid(_ date: String, through today: String) -> Bool {
    date <= today && ModelUsageHistoryStore.isDateKey(date)
}
