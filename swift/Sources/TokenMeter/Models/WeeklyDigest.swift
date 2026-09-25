import Foundation

// 每周一条的"上周用量摘要"通知:上周全部 Coding 来源 Token 合计、环比与
// 主力来源。数据与总览环比卡同源(PeriodCompare 日历周口径),纯本地计算,
// 经 Notifier 推系统通知;上周一条记录都没有就不打扰。
enum WeeklyDigest {
    struct Message: Equatable {
        let title: String
        let body: String
    }

    /// ISO 年-周标识(如 2026-W39),作为"本周已发过"的去重键。
    static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(
            format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// 周一到周三、早上 9 点后、本周还没发过 → 该发。App 周一整天没开机时,
    /// 周二/周三的首次刷新仍会补发上周摘要,更晚就等下一周。
    static func isDue(
        lastSentWeek: String?,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let weekday = calendar.component(.weekday, from: today)
        guard (2...4).contains(weekday),   // 2=周一 ... 4=周三
              calendar.component(.hour, from: today) >= 9
        else { return false }
        return lastSentWeek != weekKey(today, calendar: calendar)
    }

    /// 上周摘要文案:按 ISO 周键(与趋势图周桶一致)直接取"上周""上上周"
    /// 两个整周桶,环比复用 PeriodCompare 的口径。上周无任何用量返回 nil。
    /// 不走 DateInterval 边界判断——Darwin 的 contains 把 end 视作闭端,
    /// 回退一周复用区间时会把边界日(今天)误计进上周。
    static func message(
        _ days: [HistoryStore.DayPoint],
        participants: some Sequence<HistorySource>,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Message? {
        let allowed = Set(participants)
        guard let lastWeek = calendar.date(byAdding: .day, value: -7, to: today),
              let priorWeek = calendar.date(byAdding: .day, value: -14, to: today)
        else { return nil }
        let lastKey = weekKey(lastWeek, calendar: calendar)
        let priorKey = weekKey(priorWeek, calendar: calendar)

        var lastBySource: [HistorySource: Int] = [:]
        var priorBySource: [HistorySource: Int] = [:]
        for day in days {
            guard let date = DateUtil.date(from: day.date) else { continue }
            let key = weekKey(date, calendar: calendar)
            guard key == lastKey || key == priorKey else { continue }
            for (source, tokens) in day.bySource where allowed.contains(source) {
                if key == lastKey {
                    lastBySource[source, default: 0] += tokens
                } else {
                    priorBySource[source, default: 0] += tokens
                }
            }
        }

        let lastTotal = lastBySource.values.reduce(0, +)
        let priorTotal = priorBySource.values.reduce(0, +)
        guard lastTotal > 0 else { return nil }

        var body = "合计 \(Fmt.tokensShort(lastTotal))"
        if let change = PeriodCompare.change(this: lastTotal, last: priorTotal) {
            body += "，环比 \(change >= 0 ? "↑" : "↓") \(Fmt.percent(abs(change)))"
        }
        let top = lastBySource.max { $0.value < $1.value }
        if let top {
            if lastBySource.count > 1 {
                let share = Double(top.value) / Double(lastTotal) * 100
                body += "；主力 \(top.key.overviewName) \(Fmt.percent(share))"
            } else {
                body += "；全部来自 \(top.key.overviewName)"
            }
        }
        return Message(title: "TokenMeter 上周用量摘要", body: body)
    }

    /// 设置里已启用的 Coding 来源(DeepSeek 平台账户天然不在其列)。
    static func participants(_ store: ConfigStore) -> [HistorySource] {
        [
            store.claudeMonitorEnabled ? .claude : nil,
            store.codexMonitorEnabled ? .codex : nil,
            store.kimiMonitorEnabled ? .kimi : nil,
            store.opencodeMonitorEnabled ? .opencode : nil,
            store.geminiMonitorEnabled ? .gemini : nil,
            store.copilotMonitorEnabled ? .copilot : nil,
            store.qwenMonitorEnabled ? .qwen : nil,
            store.cursorMonitorEnabled ? .cursor : nil,
        ].compactMap { $0 }
    }
}
