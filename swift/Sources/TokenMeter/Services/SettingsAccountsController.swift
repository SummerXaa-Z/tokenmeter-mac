import Combine
import Foundation

// 常驻于设置页的交互对象；切换分区不取消网页登录订阅，也不丢输入草稿。
// 账户验证和额度采纳仍由 AppState/AccountQuotaConnections 承担。
@MainActor
final class SettingsAccountsController: ObservableObject {
    private let store = ConfigStore.shared
    private weak var state: AppState?
    private let sync = LoginSyncController()
    private var subscriptions: Set<AnyCancellable> = []
    @Published var apiKeyInput = ""
    @Published var apiStatus = ""
    @Published var usageTokenInput = ""
    @Published var usageStatus = ""
    @Published var kimiCodeKeyInput = ""
    @Published var kimiCodeKeyStatus = ""
    @Published var zhipuKeyInput = ""
    @Published var zhipuKeyStatus = ""
    @Published var showManualPaste = false
    @Published var busy = false
    @Published var syncing = false
    @Published var expandBalanceKey = false
    @Published var expandUsageToken = false
    @Published var expandKimiKey = false
    @Published var expandZhipuKey = false

    func bind(to state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        expandBalanceKey = !store.apiKeyConfigured
        expandUsageToken = !store.usageTokenConfigured
        expandKimiKey = !store.kimiCodeKeyConfigured
        expandZhipuKey = !store.zhipuKeyConfigured
        apiStatus = store.apiKeyConfigured
            ? "已配置 \(store.apiKeyPreview() ?? "")"
            : "未配置 API Key"
        usageStatus = store.usageTokenConfigured ? "用量 Token 已配置" : "未配置用量 Token"
        kimiCodeKeyStatus = store.kimiCodeKeyConfigured
            ? "已配置 \(store.kimiCodeKeyPreview() ?? "")，额度走 Kimi 官方接口"
            : "未配置；仅在 standalone kimi web 运行时尝试本机额度接口"
        zhipuKeyStatus = store.zhipuKeyConfigured
            ? "已配置 \(store.zhipuKeyPreview() ?? "")（\(store.zhipuQuotaDomain.title)）"
            : "未配置（\(store.zhipuQuotaDomain.title)）"

        sync.$captured.compactMap { $0 }.sink { [weak self] _ in
            guard let self else { return }
            self.syncing = false
            self.usageStatus = "已通过网页登录自动同步，正在刷新…"
            Task { await self.refreshUsageAfterToken("已自动同步用量 Token") }
        }.store(in: &subscriptions)
        sync.$ended.sink { [weak self] ended in
            guard ended, let self else { return }
            self.syncing = false
            self.usageStatus = "登录窗口已关闭，未获取到 Token。可重新同步或手动输入。"
        }.store(in: &subscriptions)
        sync.$persistenceError.compactMap { $0 }.sink { [weak self] message in
            self?.syncing = false
            self?.usageStatus = message
        }.store(in: &subscriptions)
    }

    func saveApiKey() {
        guard let state else { return }
        guard !RuntimeEnvironment.isIsolated else { apiStatus = "验证模式不连接真实账户"; return }
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            apiStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 API Key"
            return
        }
        busy = true
        apiStatus = "正在验证 DeepSeek 余额连接…"
        Task {
            do {
                let balance = try await DeepSeekAPI.fetchBalance(apiKey: key)
                try store.saveDeepSeekAPIKey(key)
                apiKeyInput = ""
                apiStatus = "验证通过，当前余额 \(balance.symbol)\(balance.totalBalance)\(balance.isAvailable ? "" : "（余额不足）")"
                expandBalanceKey = false
                await state.loadBalance(force: true)
            } catch {
                apiStatus = (error as? CredentialStoreError)?.errorDescription
                    ?? (error as? APIError)?.errorDescription
                    ?? "API Key 验证失败，未覆盖原凭据"
            }
            busy = false
        }
    }

    func clearApiKey() {
        guard let state else { return }
        busy = true
        do {
            try store.clearDeepSeekAPIKey()
        } catch {
            apiStatus = (error as? CredentialStoreError)?.errorDescription
                ?? "API Key 清除失败"
            busy = false
            return
        }
        apiKeyInput = ""
        apiStatus = "已清除 API Key"
        Task {
            await state.loadBalance(force: true)
            busy = false
        }
    }

    func saveKimiCodeKey() {
        guard let state else { return }
        let key = kimiCodeKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            kimiCodeKeyStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 Key"
            return
        }
        busy = true
        kimiCodeKeyStatus = "正在验证 Kimi 官方额度…"
        Task {
            do {
                switch try await state.connectKimiCode(key: key) {
                case .completed(let result):
                    kimiCodeKeyInput = ""
                    let windowCount = (result.summary == nil ? 0 : 1) + result.limits.count
                    kimiCodeKeyStatus = "验证通过，已读取 \(windowCount) 个额度窗口"
                    expandKimiKey = false
                case .superseded:
                    kimiCodeKeyStatus = "连接设置已改变，已忽略旧验证结果"
                case .isolated:
                    kimiCodeKeyStatus = "验证模式不连接真实账户"
                }
            } catch {
                kimiCodeKeyStatus = (error as? KimiQuotaError)?.errorDescription
                    ?? (error as? CredentialStoreError)?.errorDescription
                    ?? "Kimi For Coding Key 验证失败"
            }
            busy = false
        }
    }

    func clearKimiCodeKey() {
        guard let state else { return }
        busy = true
        kimiCodeKeyStatus = "正在清除并尝试本机 kimi web 额度接口…"
        Task {
            do {
                switch try await state.clearKimiCodeConnection() {
                case .completed(let status):
                    kimiCodeKeyInput = ""
                    kimiCodeKeyStatus = status
                case .superseded:
                    kimiCodeKeyStatus = "连接设置已改变，已忽略旧清除反馈"
                case .isolated:
                    kimiCodeKeyStatus = "验证模式不连接真实账户"
                }
            } catch {
                kimiCodeKeyStatus = (error as? CredentialStoreError)?.errorDescription
                    ?? "Kimi For Coding Key 清除失败"
            }
            busy = false
        }
    }

    func saveZhipuKey() {
        guard let state else { return }
        let key = zhipuKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            zhipuKeyStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 Key"
            return
        }
        busy = true
        zhipuKeyStatus = "正在验证智谱官方额度…"
        Task {
            do {
                switch try await state.connectZhipu(key: key) {
                case .completed(let result):
                    zhipuKeyInput = ""
                    zhipuKeyStatus = "验证通过，已读取 \(result.windowCount) 个额度窗口"
                    expandZhipuKey = false
                case .superseded:
                    zhipuKeyStatus = "连接设置已改变，已忽略旧验证结果"
                case .isolated:
                    zhipuKeyStatus = "验证模式不连接真实账户"
                }
            } catch {
                zhipuKeyStatus = (error as? ZhipuQuotaError)?.errorDescription
                    ?? (error as? CredentialStoreError)?.errorDescription
                    ?? "智谱 API Key 验证失败"
            }
            busy = false
        }
    }

    func clearZhipuKey() {
        guard let state else { return }
        busy = true
        do {
            switch try state.clearZhipuConnection() {
            case .completed:
                zhipuKeyInput = ""
                zhipuKeyStatus = "已清除智谱 API Key"
            case .superseded:
                zhipuKeyStatus = "连接设置已改变，已忽略旧清除反馈"
            case .isolated:
                zhipuKeyStatus = "验证模式不连接真实账户"
            }
        } catch {
            zhipuKeyStatus = (error as? CredentialStoreError)?.errorDescription
                ?? "智谱 API Key 清除失败"
            busy = false
            return
        }
        busy = false
    }

    func startSync() {
        guard !syncing else { return }
        syncing = true
        usageStatus = "请在登录窗口完成登录；捕获成功后会自动关闭并刷新。"
        _ = sync.start()
    }

    func saveUsageToken() {
        guard state != nil else { return }
        let token = usageTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            usageStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 Token"
            return
        }
        busy = true
        usageStatus = "正在验证用量 Token…"
        Task {
            let now = Date()
            let components = Calendar.current.dateComponents([.month, .year], from: now)
            let valid = await DeepSeekAPI.verifyUsageToken(
                token,
                month: components.month ?? 1,
                year: components.year ?? 2026
            )
            guard valid else {
                usageStatus = "Token 验证失败，未覆盖原凭据"
                busy = false
                return
            }
            do {
                try store.saveDeepSeekUsageToken(token)
                usageTokenInput = ""
                await refreshUsageAfterToken("验证通过，已保存")
            } catch {
                usageStatus = (error as? CredentialStoreError)?.errorDescription
                    ?? "用量 Token 保存失败"
            }
            busy = false
        }
    }

    func clearUsageToken() {
        guard let state else { return }
        busy = true
        do {
            try store.clearDeepSeekUsageToken()
        } catch {
            usageStatus = (error as? CredentialStoreError)?.errorDescription
                ?? "用量 Token 清除失败"
            busy = false
            return
        }
        usageTokenInput = ""
        usageStatus = "已清除用量 Token"
        state.clearUsage()
        busy = false
    }

    private func refreshUsageAfterToken(_ prefix: String) async {
        guard let state else { return }
        await state.loadUsage(force: true)
        if case .ok = state.usageState, let usage = state.usage {
            usageStatus = "\(prefix)，本月消费 \(Fmt.money(usage.monthCost))"
            expandUsageToken = false
        } else if case .error(let message) = state.usageState {
            usageStatus = "\(prefix)，但用量刷新失败：\(message)"
        }
    }
}
