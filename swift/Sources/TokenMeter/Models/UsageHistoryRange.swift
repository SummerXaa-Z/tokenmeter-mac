import Foundation

enum UsageTrendGranularity: String, Equatable {
    case hour = "按小时"
    case day = "按日"
    case week = "按周"
    case month = "按月"
}

// 一级时间导航。所有选项都基于本机逐日历史，不触发网络请求；“全部”指
// TokenMeter 从安装使用后在本机实际积累的历史，不代表平台账号终身数据。
enum UsageHistoryRange: Int, CaseIterable, Identifiable, Hashable {
    case day = 1
    case week = 7
    case month = 30
    case all = 0

    var id: Int { rawValue }
    var tabTitle: String {
        switch self {
        case .day: return "1D"
        case .week: return "7D"
        case .month: return "30D"
        case .all: return "全部"
        }
    }
    var scopeTitle: String {
        switch self {
        case .day: return "今日"
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .all: return "全部历史"
        }
    }
    var fixedDayCount: Int? {
        self == .all ? nil : rawValue
    }

    func slice<T>(_ values: [T]) -> [T] {
        guard let fixedDayCount else { return values }
        return Array(values.suffix(fixedDayCount))
    }

    // 固定范围保持逐日；“全部”随本机历史长度降采样，避免在 420pt 宽的
    // 菜单栏面板里挤出数百根不可读的柱子。
    func trendGranularity(historyDayCount: Int) -> UsageTrendGranularity {
        if self == .day { return .hour }
        guard self == .all else { return .day }
        if historyDayCount <= 90 { return .day }
        if historyDayCount <= 730 { return .week }
        return .month
    }

    // 明确“全部”只是 TokenMeter 本机历史；固定窗口尚未积满时也如实标注，
    // 不把不足 30 天的数据伪装成完整 30 天。
    func localCoverageText(historyStartDate: String?, availableDays: Int) -> String? {
        guard let historyStartDate, availableDays > 0 else {
            return self == .all ? "尚未积累本机历史" : nil
        }
        let start = Fmt.ymd(historyStartDate)
        if self == .all {
            return "本机记录始于 \(start) · 此前用量不包含 · 共 \(availableDays) 天"
        }
        guard let fixedDayCount, availableDays < fixedDayCount else { return nil }
        return "本机记录始于 \(start) · 当前覆盖 \(availableDays)/\(fixedDayCount) 天"
    }
}
