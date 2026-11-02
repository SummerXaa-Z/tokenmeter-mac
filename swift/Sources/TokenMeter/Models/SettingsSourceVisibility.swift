import Foundation

// 路径是否存在不等于用户是否还需要这份历史。失去数据路径的来源仍须
// 能停用；历史来源停用后保留开关，允许重新展示，但不删除留存。
struct SettingsSourceVisibility: Equatable {
    let available: Bool
    let enabled: Bool
    let hasHistory: Bool

    var showsToggle: Bool { available || enabled || hasHistory }

    var unavailableExplanation: String? {
        guard !available else { return nil }
        return hasHistory
            ? "未检测到数据；开关仅控制留存展示，关闭不会删除历史。"
            : "未检测到数据；可关闭监控，已有留存不会删除。"
    }

    static func hasHistory(
        for source: HistorySource, daily: [HistoryStore.DayPoint], models: [ModelUsageDay]
    ) -> Bool {
        daily.contains { ($0.bySource[source] ?? 0) > 0 }
            || models.contains { $0.bySource[source].map { !$0.isEmpty } ?? false }
    }
}
