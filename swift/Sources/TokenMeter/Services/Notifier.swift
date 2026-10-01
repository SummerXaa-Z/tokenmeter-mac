import Foundation
import UserNotifications

// 系统通知封装：配额/用量越线时弹 macOS 通知，补足"不主动开面板就发现不了"
// 的盲区（菜单栏图标着色仍保留作为常驻视觉提示）。
//
// 自签名非沙盒 app 上 UNUserNotificationCenter 可用，但权限申请可能被系统
// 拒（取决于签名信任）。所有调用容错：失败不抛、不崩，静默退回图标着色。
enum Notifier {
    // 周报摘要通知的 identifier：发送方与点击路由共用，改这里即可换键。
    static let weeklyDigestID = "weekly.digest"

    // 仅在有有效 bundle 时使用通知中心，避免裸进程调 current() 崩溃
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func requestAuthorizationIfEnabled(_ enabled: Bool) {
        requestAuthorizationIfEnabled(enabled, request: requestAuthorization)
    }

    // 注入 request 让开关门禁可在 XCTest 中验证，而不触碰真实系统通知中心。
    static func requestAuthorizationIfEnabled(_ enabled: Bool, request: () -> Void) {
        guard enabled else { return }
        request()
    }

    // 推一条通知。identifier 相同会替换上一条（同类告警不堆叠）。
    static func send(id: String, title: String, body: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // 用户可能在授权查询期间关闭应用内通知；回主线程做最终门禁，
            // 保证检查与入队之间不会插入一次设置切换。
            DispatchQueue.main.async {
                guard shouldEnqueue(
                    authorizationStatus: settings.authorizationStatus,
                    notificationsEnabled: ConfigStore.shared.notificationsEnabled
                ) else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
                center.add(req)
            }
        }
    }

    static func shouldEnqueue(
        authorizationStatus: UNAuthorizationStatus,
        notificationsEnabled: Bool
    ) -> Bool {
        notificationsEnabled
            && (authorizationStatus == .authorized || authorizationStatus == .provisional)
    }

    /// 通知横幅本身的点击（默认动作）应打开的页面：周报回总览；配额/用量
    /// 告警跳对应来源页；跨来源的节奏预警与只在总览露面的订阅额度
    /// （智谱/方舟）也回总览。派生动作（展开/关闭等）与未知通知返回
    /// nil 不跳转——只有用户明确点了横幅才抢焦点弹面板。
    static func openTarget(
        identifier: String,
        actionIdentifier: String
    ) -> AppView? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else {
            return nil
        }
        if identifier == weeklyDigestID { return .dashboard }
        switch identifier {
        case "codex.quota.low": return .source(.codex)
        case "claude.daily.over": return .source(.claude)
        case "kimi.quota.low": return .source(.kimi)
        case "deepseek.balance.low": return .source(.deepseek)
        case "zhipu.quota.low", "ark.quota.low": return .dashboard
        default:
            // 节奏预警 key 带窗口重置时刻（quota.pace.<period>@<reset>），前缀匹配
            return identifier.hasPrefix("quota.pace.") ? .dashboard : nil
        }
    }
}
