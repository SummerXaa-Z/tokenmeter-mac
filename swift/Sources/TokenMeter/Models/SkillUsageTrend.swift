import Foundation

// Skills 榜迷你条的取数:近 N 周逐周调用次数。与总览 Skill 聚合同一批
// 证据(实时 daySkills 整天权威覆盖留存同一天该来源的次数,其余来源与
// 其余天取本机留存),按自然周(周一为界,与热力图/趋势周口径一致)分桶。
// 只聚合次数,不接触 transcript、工具参数或 SKILL.md 内容。
enum SkillUsageTrend {
    /// 某 Skill 近 `weeks` 周的逐周调用次数(升序、含本周,空周计 0);
    /// 窗口内一次都没有返回 nil(与模型榜迷你趋势的断流语义一致)。
    /// Skill 名跨来源合并(榜内同名 Skill 是同一行)。
    static func weeklyCounts(
        name: String,
        weeks: Int,
        liveSkills: [HistorySource: [String: [String: Int]]],
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today(),
        calendar: Calendar = .current
    ) -> [(weekOf: String, count: Int)]? {
        guard weeks > 0,
              !name.isEmpty,
              let today = DateUtil.date(from: todayKey)
        else { return nil }
        // 本周周一往前推 (weeks - 1) 周为窗口起点(含今天的整周)
        let thisMonday = UsageHeatmap.mondayKey(of: today, calendar: calendar)
        guard let mondayDate = DateUtil.date(from: thisMonday),
              let windowStart = calendar.date(
                  byAdding: .weekOfYear, value: -(weeks - 1), to: mondayDate)
        else { return nil }
        let startKey = DateUtil.key(windowStart)

        // 日 → 来源 → 该 Skill 当日次数;留存先填,实时按来源整天覆盖
        // (该来源当天窗口里没有此 Skill 名即当日 0,清掉留存旧值)
        var perDayBySource: [String: [HistorySource: Int]] = [:]
        for day in persisted
        where day.date >= startKey && day.date <= todayKey {
            for (source, detail) in day.bySource {
                if let count = detail.skills[name] {
                    perDayBySource[day.date, default: [:]][source] = count
                }
            }
        }
        for (source, byDate) in liveSkills {
            for (date, byName) in byDate
            where date >= startKey && date <= todayKey
                  && ModelUsageHistoryStore.isDateKey(date) {
                perDayBySource[date, default: [:]][source] = byName[name] ?? 0
            }
        }

        // 按周(周一锚定)分桶,跨来源求和
        var byWeek: [String: Int] = [:]
        for (date, bySource) in perDayBySource {
            guard let day = DateUtil.date(from: date) else { continue }
            let week = UsageHeatmap.mondayKey(of: day, calendar: calendar)
            byWeek[week, default: 0] += bySource.values.reduce(0, +)
        }

        var result: [(weekOf: String, count: Int)] = []
        for offset in 0..<weeks {
            guard let monday = calendar.date(
                byAdding: .weekOfYear, value: offset, to: windowStart)
            else { continue }
            let key = DateUtil.key(monday)
            result.append((weekOf: key, count: byWeek[key] ?? 0))
        }
        return result.contains { $0.count > 0 } ? result : nil
    }
}
