import Foundation

// 状态栏异步刷新只允许按仍然有效的设置落地。扫描期间若用户改了任一相关设置，
// 旧任务的图标和通知结果必须丢弃，由 StatusRefreshCoalescer 补跑最新状态。
struct StatusRefreshSettings: Equatable {
    let deepseekEnabled: Bool
    let deepseekBalanceAlertThreshold: Int
    let claudeEnabled: Bool
    let claudeDailyLimitM: Int
    let codexEnabled: Bool
    let menubarInfoMode: String
    let notificationsEnabled: Bool

    func isCurrent(_ current: StatusRefreshSettings) -> Bool {
        self == current
    }
}
