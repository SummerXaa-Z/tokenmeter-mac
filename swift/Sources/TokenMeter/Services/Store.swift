import Foundation
import Security

// 凭据存 Keychain（比 Tauri 版的明文 config.json 更安全），
// 设置项存 UserDefaults。对外暴露与原版 AppConfig 等价的视图。

// Keychain account 标识（仅作为存储键名，非凭据本身）
enum SecretSlot: String {
    case balanceKey = "deepseek.slot.balance"
    case usageGrant = "deepseek.slot.usage"
}

struct Keychain {
    static let service = "com.deepseek.monitor.mac"

    static func set(_ value: String, for slot: SecretSlot) {
        let account = slot.rawValue
        // 先删旧值再写，避免 duplicate
        delete(slot)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ slot: SecretSlot) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8), !str.isEmpty
        else { return nil }
        return str
    }

    static func delete(_ slot: SecretSlot) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// 应用配置：凭据走 Keychain，偏好走 UserDefaults。
final class ConfigStore {
    static let shared = ConfigStore()
    private let defaults = UserDefaults.standard

    private enum DKey {
        static let refreshInterval = "refreshIntervalSeconds"
        static let autoRefresh = "autoRefreshEnabled"
        static let autostart = "autostart"
        static let deepseekMonitor = "deepseekMonitorEnabled"
        static let claudeMonitor = "claudeMonitorEnabled"
        static let codexMonitor = "codexMonitorEnabled"
        static let cursorMonitor = "cursorMonitorEnabled"
        static let menubarInfo = "menubarInfoMode"
        static let claudeDailyTokenLimit = "claudeDailyTokenLimitM"
        static let autoUpdateCheck = "autoUpdateCheckEnabled"
        static let lastUpdateCheck = "lastUpdateCheckAt"
    }

    // 合法刷新间隔，对应 Rust normalize_refresh_interval_seconds
    static let allowedIntervals = [60, 300, 1800, 3600]

    var credApiKey: String? {
        get { Keychain.get(.balanceKey) }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, for: .balanceKey) }
            else { Keychain.delete(.balanceKey) }
        }
    }

    var credUsageToken: String? {
        get { Keychain.get(.usageGrant) }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, for: .usageGrant) }
            else { Keychain.delete(.usageGrant) }
        }
    }

    var refreshIntervalSeconds: Int {
        get {
            let v = defaults.integer(forKey: DKey.refreshInterval)
            return Self.allowedIntervals.contains(v) ? v : 60
        }
        set {
            let v = Self.allowedIntervals.contains(newValue) ? newValue : 60
            defaults.set(v, forKey: DKey.refreshInterval)
        }
    }

    var autoRefreshEnabled: Bool {
        get { defaults.bool(forKey: DKey.autoRefresh) }
        set { defaults.set(newValue, forKey: DKey.autoRefresh) }
    }

    var autostart: Bool {
        get { defaults.bool(forKey: DKey.autostart) }
        set { defaults.set(newValue, forKey: DKey.autostart) }
    }

    // 监控源开关：默认开（无记录视为 true），关闭后对应 tab 隐藏且不再扫描/请求
    var deepseekMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.deepseekMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.deepseekMonitor) }
    }

    var claudeMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.claudeMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.claudeMonitor) }
    }

    var codexMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.codexMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.codexMonitor) }
    }

    var cursorMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.cursorMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.cursorMonitor) }
    }

    // 菜单栏图标旁文字："off" 不显示 / "claude" 今日 token / "codex" 配额剩余
    var menubarInfoMode: String {
        get { defaults.string(forKey: DKey.menubarInfo) ?? "claude" }
        set { defaults.set(newValue, forKey: DKey.menubarInfo) }
    }

    // Claude 日用量预警阈值（单位百万 token）：0 = 关闭预警。
    // integer(forKey:) 无记录返回 0，恰好就是默认关闭，无需哨兵值
    var claudeDailyTokenLimitM: Int {
        get { defaults.integer(forKey: DKey.claudeDailyTokenLimit) }
        set { defaults.set(newValue, forKey: DKey.claudeDailyTokenLimit) }
    }

    // 自动检查更新：默认开，每日最多一次（启动时触发）
    var autoUpdateCheckEnabled: Bool {
        get { defaults.object(forKey: DKey.autoUpdateCheck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.autoUpdateCheck) }
    }

    var lastUpdateCheckAt: TimeInterval {
        get { defaults.double(forKey: DKey.lastUpdateCheck) }
        set { defaults.set(newValue, forKey: DKey.lastUpdateCheck) }
    }

    // 凭据预览，对应 Rust api_key_preview（脱敏，只露头尾）
    func apiKeyPreview() -> String? {
        guard let key = credApiKey, !key.isEmpty else { return nil }
        let chars = Array(key)
        if chars.count <= 12 { return "已保存" }
        let start = String(chars.prefix(7))
        let end = String(chars.suffix(4))
        return "\(start)...\(end)"
    }

    var apiKeyConfigured: Bool { credApiKey?.isEmpty == false }
    var usageTokenConfigured: Bool { credUsageToken?.isEmpty == false }
}
