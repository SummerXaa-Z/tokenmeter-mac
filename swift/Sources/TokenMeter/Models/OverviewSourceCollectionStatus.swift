import Foundation

struct OverviewSourceCollectionStatus: Identifiable {
    enum Phase: Equatable { case loading, failed, ready, unavailable }
    let provider: Provider
    let loading: Bool
    let hasResult: Bool
    let error: String?
    let available: Bool
    var id: Provider { provider }

    var phase: Phase {
        if loading { return .loading }
        if error != nil { return .failed }
        if hasResult { return .ready }
        return available ? .loading : .unavailable
    }

    static func totalIsUnknown(_ total: Int, statuses: [Self]) -> Bool {
        total == 0 && statuses.contains { $0.phase == .loading || $0.phase == .failed }
    }

    static func message(total: Int, statuses: [Self], hasSelection: Bool) -> String? {
        if !hasSelection { return "尚未启用用量来源" }
        if statuses.contains(where: { $0.phase == .failed }) {
            return total > 0 ? "部分来源读取失败，显示已留存用量" : "来源读取失败，用量暂不可确认"
        }
        if statuses.contains(where: { $0.phase == .loading }) {
            return total > 0 ? "正在刷新来源，先显示已留存用量…" : "正在读取本地用量…"
        }
        if !statuses.isEmpty, statuses.allSatisfy({ $0.phase == .unavailable }) {
            return "未检测到本地数据，可在设置中查看来源"
        }
        return total == 0 ? "所选时间范围暂无 Agent 用量" : nil
    }
}
