import Foundation

// DeepSeek 缓存命中明细卡导出 CSV：近 7 天滚动窗口（含今天）逐日一行，
// 命中/未命中/输出三列与卡片图例同名同口径（V4 Flash + Pro 合并）。
// 命中率分母只有命中 + 未命中，输出不计入——与卡片头部摘要一致。
enum DeepSeekCacheCSVExport {
    static func makeCSV(
        days: [UsageDay],
        todayKey: String = DateUtil.today()
    ) -> String {
        let ordered = DateUtil.recentDays(days)
        var lines: [[String]] = []
        lines.append(["日期", "星期", "命中", "未命中", "输出", "合计"])
        for day in ordered {
            lines.append(row(for: day))
        }
        if !ordered.isEmpty {
            lines.append(totalRow(days: ordered))
        }
        appendNotes(to: &lines, days: ordered, todayKey: todayKey)
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func row(for day: UsageDay) -> [String] {
        let hit = day.flashCacheHit + day.proCacheHit
        let miss = day.flashCacheMiss + day.proCacheMiss
        let resp = day.flashResponse + day.proResponse
        return [
            day.date, weekday(of: day.date),
            String(hit), String(miss), String(resp), String(hit + miss + resp),
        ]
    }

    private static func totalRow(days: [UsageDay]) -> [String] {
        var hit = 0, miss = 0, resp = 0
        for day in days {
            hit += day.flashCacheHit + day.proCacheHit
            miss += day.flashCacheMiss + day.proCacheMiss
            resp += day.flashResponse + day.proResponse
        }
        return ["合计", "", String(hit), String(miss), String(resp), String(hit + miss + resp)]
    }

    /// 日期键 → 周几（与热力图/来源页趋势导出同一写法）；非法日期留空
    private static func weekday(of dateKey: String) -> String {
        guard let date = DateUtil.date(from: dateKey) else { return "" }
        return HeatmapCSVExport.weekdayLabel(
            Calendar.current.component(.weekday, from: date))
    }

    private static func appendNotes(
        to lines: inout [[String]], days: [UsageDay], todayKey: String
    ) {
        var hit = 0, miss = 0
        for day in days {
            hit += day.flashCacheHit + day.proCacheHit
            miss += day.flashCacheMiss + day.proCacheMiss
        }
        let rate = (hit + miss) > 0 ? Int(Double(hit) / Double(hit + miss) * 100) : 0
        let notes: [String] = [
            "口径",
            "DeepSeek 平台 · 近 7 天滚动窗口含今天（与卡片同窗口）",
            "V4 Flash 与 V4 Pro 合并展示（与卡片图例一致）",
            "命中率 = 命中 ÷（命中 + 未命中），输出不计入分母；窗口合计命中率 \(rate)%",
            "Token 为原始整数",
            "导出于 \(todayKey)",
        ]
        for note in notes {
            lines.append([ModelRankingCSVExport.escaped(note)])
        }
    }

    static func suggestedFilename(
        todayKey: String = DateUtil.today()
    ) -> String {
        return "TokenMeter-deepseek-cache-\(todayKey).csv"
    }
}
