import Foundation
import UserNotifications

// 系统通知封装：配额/用量越线时弹 macOS 通知，补足"不主动开面板就发现不了"
// 的盲区（菜单栏图标着色仍保留作为常驻视觉提示）。
//
// 自签名非沙盒 app 上 UNUserNotificationCenter 可用，但权限申请可能被系统
// 拒（取决于签名信任）。所有调用容错：失败不抛、不崩，静默退回图标着色。
enum Notifier {
    // 周报摘要通知的 identifier 基键：发送方与点击路由共用，改这里即可换键。
    // 实际发送用 weeklyDigestID(forWeek:) 按所述周派生——每周各一条，
    // 系统通知中心里互不顶替（identifier 相同才替换）。
    static let weeklyDigestID = "weekly.digest"

    /// 周报通知的按周 identifier（如 weekly.digest.2026-W39），周键与
    /// 周报文案管线同源（WeeklyDigest.weekKey，ISO 年-周）。裸基键仅作
    /// 旧版已发出通知的点击路由兼容。
    static func weeklyDigestID(forWeek weekKey: String) -> String {
        "\(weeklyDigestID).\(weekKey)"
    }

    /// 通知分组（threadIdentifier）：macOS 通知中心把同组通知折叠成一条
    /// 堆叠。周报一组（按周留痕后逐周堆积也能收拢）、配额/用量/余额
    /// 告警一组、节奏预警一组；未知键自成一组（用 id 本身，绝不与已知
    /// 组混叠）。send 自动按 id 挂组，调用方无需关心。
    static func threadIdentifier(for id: String) -> String {
        if id == weeklyDigestID || id.hasPrefix(weeklyDigestID + ".") {
            return "weekly.digest"
        }
        if id.hasPrefix("quota.pace.") { return "quota.pace" }
        switch id {
        case "codex.quota.low", "claude.daily.over", "kimi.quota.low",
             "deepseek.balance.low", "zhipu.quota.low", "ark.quota.low":
            return "quota.alert"
        default:
            return id
        }
    }

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
                // 同类通知在通知中心按组折叠（周报/告警/节奏各一组）
                content.threadIdentifier = threadIdentifier(for: id)
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

    /// 设置页「推样例」用的告警样例：文案与真实告警同构、id 与真实告警
    /// 同键——点击横幅即走同一条跳转路由（来源页/总览），不越线也能验证。
    /// 样例会顶掉同键待处理的真实通知（identifier 相同即替换），可接受：
    /// 用户主动点的预览，真实告警触发时横幅早已展示过。
    static func alertSamples() -> [(id: String, title: String, body: String)] {
        [
            (id: "codex.quota.low",
             title: "Codex 配额告急",
             body: "【样例】订阅配额仅剩 8%，留意用量"),
            (id: "claude.daily.over",
             title: "Claude 日用量越线",
             body: "【样例】今日已用 320M，超过 300M 阈值"),
            (id: "kimi.quota.low",
             title: "Kimi Code 额度告急",
             body: "【样例】订阅额度仅剩 9%，留意用量"),
            (id: "deepseek.balance.low",
             title: "DeepSeek 余额不足",
             body: "【样例】当前余额 ¥12.50，低于 20 预警线"),
            (id: "zhipu.quota.low",
             title: "智谱 GLM 额度告急",
             body: "【样例】订阅额度仅剩 6%，留意用量"),
            (id: "ark.quota.low",
             title: "火山方舟额度告急",
             body: "【样例】订阅额度仅剩 7%，留意用量"),
            (id: "quota.pace.sample",
             title: "Codex 周额度可能提前用完",
             body: "【样例】已用 78%，窗口时间才过 40%；按当前速度约 周四 21:00 耗尽，早于 周一 09:00 重置"),
        ]
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
        // 周报按周留痕：带周键的派生 id 与旧版裸键都回总览（升级前已
        // 发出的通知点击仍可跳转）；前缀必须是完整基键，避免误伤相近键。
        if identifier == weeklyDigestID
            || identifier.hasPrefix(weeklyDigestID + ".")
        { return .dashboard }
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
