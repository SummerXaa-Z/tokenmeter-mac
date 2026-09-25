import Foundation
import Security

// 凭据存 Keychain（比 Tauri 版的明文 config.json 更安全），
// 设置项存 UserDefaults。对外暴露与原版 AppConfig 等价的视图。

// Keychain account 标识（仅作为存储键名，非凭据本身）
enum SecretSlot: String {
    case balanceKey = "deepseek.slot.balance"
    case usageGrant = "deepseek.slot.usage"
    case kimiCodeKey = "kimi-code.slot.quota"
    case zhipuCodeKey = "zhipu.slot.quota"
}

struct Keychain {
    static let service = "com.deepseek.monitor.mac"

    @discardableResult
    static func set(_ value: String, for slot: SecretSlot) -> OSStatus {
        let account = slot.rawValue
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            return errSecParam
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var addQuery = query
        addQuery.merge([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil)
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

    @discardableResult
    static func delete(_ slot: SecretSlot) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

enum CredentialStoreError: LocalizedError, Equatable {
    case emptyCredential
    case keychainWriteFailed
    case keychainDeleteFailed

    var errorDescription: String? {
        switch self {
        case .emptyCredential:
            return "凭据不能为空，原凭据已保留"
        case .keychainWriteFailed:
            return "无法安全写入本机 Keychain，原凭据已保留"
        case .keychainDeleteFailed:
            return "无法从本机 Keychain 清除凭据，原凭据仍保留"
        }
    }
}

// 应用配置：凭据走 Keychain，偏好走 UserDefaults。
final class ConfigStore {
    static let shared = ConfigStore()
    private let defaults: UserDefaults
    private let keychainGet: (SecretSlot) -> String?
    private let keychainSet: (String, SecretSlot) -> OSStatus
    private let keychainDelete: (SecretSlot) -> OSStatus

    init(
        defaults: UserDefaults = .standard,
        keychainGet: @escaping (SecretSlot) -> String? = Keychain.get,
        keychainSet: @escaping (String, SecretSlot) -> OSStatus = Keychain.set,
        keychainDelete: @escaping (SecretSlot) -> OSStatus = Keychain.delete
    ) {
        self.defaults = defaults
        self.keychainGet = keychainGet
        self.keychainSet = keychainSet
        self.keychainDelete = keychainDelete
    }

    private enum DKey {
        static let refreshInterval = "refreshIntervalSeconds"
        static let autoRefresh = "autoRefreshEnabled"
        static let autostart = "autostart"
        static let deepseekMonitor = "deepseekMonitorEnabled"
        static let claudeMonitor = "claudeMonitorEnabled"
        static let codexMonitor = "codexMonitorEnabled"
        static let kimiMonitor = "kimiMonitorEnabled"
        static let opencodeMonitor = "opencodeMonitorEnabled"
        static let geminiMonitor = "geminiMonitorEnabled"
        static let copilotMonitor = "copilotMonitorEnabled"
        static let qwenMonitor = "qwenMonitorEnabled"
        static let cursorMonitor = "cursorMonitorEnabled"
        static let menubarInfo = "menubarInfoMode"
        static let zhipuQuotaDomain = "zhipuQuotaDomain"
        static let claudeDailyTokenLimit = "claudeDailyTokenLimitM"
        static let autoUpdateCheck = "autoUpdateCheckEnabled"
        static let lastUpdateCheck = "lastUpdateCheckAt"
        static let notifications = "notificationsEnabled"
        static let weeklyDigest = "weeklyDigestEnabled"
        static let lastWeeklyDigest = "lastWeeklyDigestWeek"
        static let quotaPaceAlert = "quotaPaceAlertEnabled"
        static let deepseekBalanceAlert = "deepseekBalanceAlertThreshold"
        static let overviewHistoryRange = "overviewHistoryRangeDays"
    }

    var overviewHistoryRangeDays: Int {
        get {
            let value = defaults.integer(forKey: DKey.overviewHistoryRange)
            // UserDefaults 未写入和“全部”都为 0，因此用 object 判断是否存在。
            guard defaults.object(forKey: DKey.overviewHistoryRange) != nil else {
                return UsageHistoryRange.month.rawValue
            }
            return UsageHistoryRange(rawValue: value)?.rawValue
                ?? UsageHistoryRange.month.rawValue
        }
        set {
            let normalized = UsageHistoryRange(rawValue: newValue) ?? .month
            defaults.set(normalized.rawValue, forKey: DKey.overviewHistoryRange)
        }
    }

    // 合法刷新间隔，对应 Rust normalize_refresh_interval_seconds
    static let allowedIntervals = [60, 300, 1800, 3600]

    var credApiKey: String? { keychainGet(.balanceKey) }

    var credUsageToken: String? { keychainGet(.usageGrant) }

    func saveDeepSeekAPIKey(_ value: String) throws {
        try saveCredential(value, slot: .balanceKey)
    }

    func clearDeepSeekAPIKey() throws {
        try clearCredential(slot: .balanceKey)
    }

    func saveDeepSeekUsageToken(_ value: String) throws {
        try saveCredential(value, slot: .usageGrant)
    }

    func clearDeepSeekUsageToken() throws {
        try clearCredential(slot: .usageGrant)
    }

    // Kimi For Coding 凭据只用于读取官方订阅额度，不参与本地 session 扫描。
    var credKimiCodeKey: String? { keychainGet(.kimiCodeKey) }

    func saveKimiCodeKey(_ value: String) throws {
        try saveCredential(value, slot: .kimiCodeKey)
    }

    func clearKimiCodeKey() throws {
        try clearCredential(slot: .kimiCodeKey)
    }

    // 智谱 GLM Coding Plan 凭据只用于读取官方订阅额度，不参与本地 session 扫描。
    var credZhipuKey: String? { keychainGet(.zhipuCodeKey) }

    func saveZhipuKey(_ value: String) throws {
        try saveCredential(value, slot: .zhipuCodeKey)
    }

    func clearZhipuKey() throws {
        try clearCredential(slot: .zhipuCodeKey)
    }

    // 智谱分国内站（open.bigmodel.cn）与国际站（api.z.ai），账号与 Key 不互通。
    var zhipuQuotaDomain: ZhipuQuotaDomain {
        get {
            guard let raw = defaults.string(forKey: DKey.zhipuQuotaDomain),
                  let domain = ZhipuQuotaDomain(rawValue: raw) else {
                return .china
            }
            return domain
        }
        set {
            defaults.set(newValue.rawValue, forKey: DKey.zhipuQuotaDomain)
        }
    }

    private func saveCredential(_ value: String, slot: SecretSlot) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CredentialStoreError.emptyCredential
        }
        guard keychainSet(normalized, slot) == errSecSuccess else {
            throw CredentialStoreError.keychainWriteFailed
        }
    }

    private func clearCredential(slot: SecretSlot) throws {
        let status = keychainDelete(slot)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainDeleteFailed
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

    var kimiMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.kimiMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.kimiMonitor) }
    }

    var opencodeMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.opencodeMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.opencodeMonitor) }
    }

    var geminiMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.geminiMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.geminiMonitor) }
    }

    var copilotMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.copilotMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.copilotMonitor) }
    }

    var qwenMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.qwenMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.qwenMonitor) }
    }

    var cursorMonitorEnabled: Bool {
        get { defaults.object(forKey: DKey.cursorMonitor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.cursorMonitor) }
    }


    // 菜单栏图标旁文字："off" / "total" 今日合计 / "claude" 今日 / "codex" 配额剩余
    var menubarInfoMode: String {
        get { defaults.string(forKey: DKey.menubarInfo) ?? "total" }
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

    // 系统通知预警：默认开。配额/用量从正常翻转到越线时推一条系统通知。
    var notificationsEnabled: Bool {
        get { defaults.object(forKey: DKey.notifications) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.notifications) }
    }

    // 每周一用量周报：默认开。周一至周三上午 9 点后各推一条上周摘要
    // (见 WeeklyDigest),受上面"系统通知"总开关约束。
    var weeklyDigestEnabled: Bool {
        get { defaults.object(forKey: DKey.weeklyDigest) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.weeklyDigest) }
    }

    // 额度提前耗尽预测提醒：默认开。长窗口（周/月）按当前速度会在重置前
    // 用完时提醒一次（见 QuotaPaceAlert），受"系统通知"总开关约束。
    var quotaPaceAlertEnabled: Bool {
        get { defaults.object(forKey: DKey.quotaPaceAlert) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DKey.quotaPaceAlert) }
    }

    // 上次已发周报的 ISO 周键(WeeklyDigest.weekKey),用于每周去重
    var lastWeeklyDigestWeek: String? {
        get { defaults.string(forKey: DKey.lastWeeklyDigest) }
        set { defaults.set(newValue, forKey: DKey.lastWeeklyDigest) }
    }

    // DeepSeek 余额预警阈值（与余额同单位，元）：余额低于此值推通知。
    // 0 = 关闭。integer(forKey:) 无记录返回 0，恰好默认关闭。
    var deepseekBalanceAlertThreshold: Int {
        get { defaults.integer(forKey: DKey.deepseekBalanceAlert) }
        set { defaults.set(newValue, forKey: DKey.deepseekBalanceAlert) }
    }

    // 凭据预览，对应 Rust api_key_preview（脱敏，只露头尾）
    func apiKeyPreview() -> String? {
        guard let key = credApiKey, !key.isEmpty else { return nil }
        return Self.credentialPreview(key)
    }

    func kimiCodeKeyPreview() -> String? {
        guard let key = credKimiCodeKey, !key.isEmpty else { return nil }
        return Self.credentialPreview(key)
    }

    func zhipuKeyPreview() -> String? {
        guard let key = credZhipuKey, !key.isEmpty else { return nil }
        return Self.credentialPreview(key)
    }

    private static func credentialPreview(_ key: String) -> String {
        let chars = Array(key)
        if chars.count <= 12 { return "已保存" }
        let start = String(chars.prefix(7))
        let end = String(chars.suffix(4))
        return "\(start)...\(end)"
    }

    var apiKeyConfigured: Bool { credApiKey?.isEmpty == false }
    var usageTokenConfigured: Bool { credUsageToken?.isEmpty == false }
    var kimiCodeKeyConfigured: Bool { credKimiCodeKey?.isEmpty == false }
    var zhipuKeyConfigured: Bool { credZhipuKey?.isEmpty == false }
}
