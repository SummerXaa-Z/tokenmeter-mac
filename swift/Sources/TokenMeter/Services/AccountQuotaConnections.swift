import Foundation

// 只协调用户明确发起的账户连接，不拥有配额快照。快照仍由 AppState 接纳。
// 后台刷新使用相同请求上下文，避免“验证保存”和“定时刷新”各有一套采纳规则。
protocol AccountQuotaCredentialStore: AnyObject {
    var credKimiCodeKey: String? { get }
    var credZhipuKey: String? { get }
    var kimiCodeKeyRead: CredentialReadResult { get }
    var zhipuKeyRead: CredentialReadResult { get }
    var zhipuQuotaDomain: ZhipuQuotaDomain { get set }
    func saveKimiCodeKey(_ value: String) throws
    func clearKimiCodeKey() throws
    func saveZhipuKey(_ value: String) throws
    func clearZhipuKey() throws
}

extension AccountQuotaCredentialStore {
    var kimiCodeKeyRead: CredentialReadResult {
        credKimiCodeKey.map(CredentialReadResult.found) ?? .missing
    }
    var zhipuKeyRead: CredentialReadResult {
        credZhipuKey.map(CredentialReadResult.found) ?? .missing
    }
}

extension ConfigStore: AccountQuotaCredentialStore {}

enum AccountQuotaConnectionOutcome<Value> {
    case completed(Value)
    case superseded
    case isolated
}

@MainActor
final class AccountQuotaConnections {
    struct KimiRequest: Equatable {
        let credential: String?
        var credentialError: CredentialStoreError? = nil
        let generation: UInt
    }

    struct ZhipuRequest: Equatable {
        let credential: String?
        var credentialError: CredentialStoreError? = nil
        let domain: ZhipuQuotaDomain
        let generation: UInt
    }

    private let store: AccountQuotaCredentialStore
    private let permitsConnections: () -> Bool
    private let loadKimi: (String) async throws -> KimiQuotaResult
    private let loadZhipu: (String, ZhipuQuotaDomain) async throws -> ZhipuQuotaResult
    private let onKimiChanged: (KimiQuotaResult?) -> Void
    private let onZhipuChanged: (ZhipuQuotaResult?) -> Void
    private var kimiGeneration: UInt = 0
    private var zhipuGeneration: UInt = 0

    init(
        store: AccountQuotaCredentialStore,
        permitsConnections: @escaping () -> Bool = { !RuntimeEnvironment.isIsolated },
        loadKimi: @escaping (String) async throws -> KimiQuotaResult = {
            try await KimiQuotaService().load(apiKey: $0)
        },
        loadZhipu: @escaping (String, ZhipuQuotaDomain) async throws -> ZhipuQuotaResult = {
            try await ZhipuQuotaService().load(apiKey: $0, domain: $1)
        },
        onKimiChanged: @escaping (KimiQuotaResult?) -> Void,
        onZhipuChanged: @escaping (ZhipuQuotaResult?) -> Void
    ) {
        self.store = store
        self.permitsConnections = permitsConnections
        self.loadKimi = loadKimi
        self.loadZhipu = loadZhipu
        self.onKimiChanged = onKimiChanged
        self.onZhipuChanged = onZhipuChanged
    }

    func kimiRequest() -> KimiRequest {
        let read = store.kimiCodeKeyRead
        return KimiRequest(
            credential: normalized(read.value), credentialError: read.error,
            generation: kimiGeneration)
    }

    func zhipuRequest() -> ZhipuRequest {
        let read = store.zhipuKeyRead
        return ZhipuRequest(
            credential: normalized(read.value), credentialError: read.error, domain: store.zhipuQuotaDomain,
            generation: zhipuGeneration)
    }

    func accepts(_ request: KimiRequest) -> Bool { request == kimiRequest() }
    func accepts(_ request: ZhipuRequest) -> Bool { request == zhipuRequest() }

    // 刷新与验证成功都通过同一个快照回调；这里不保存状态、也不写凭据。
    @discardableResult
    func acceptKimiRefresh(_ result: KimiQuotaResult, request: KimiRequest) -> Bool {
        guard request.credentialError == nil, accepts(request) else { return false }
        onKimiChanged(result)
        return true
    }

    @discardableResult
    func acceptZhipuRefresh(_ result: ZhipuQuotaResult, request: ZhipuRequest) -> Bool {
        guard request.credentialError == nil, accepts(request) else { return false }
        onZhipuChanged(result)
        return true
    }

    func connectKimi(key input: String) async throws -> AccountQuotaConnectionOutcome<KimiQuotaResult> {
        guard permitsConnections() else { return .isolated }
        guard let key = normalized(input) else { throw CredentialStoreError.emptyCredential }
        kimiGeneration &+= 1
        let request = kimiRequest()
        if let error = request.credentialError { throw error }
        do {
            let result = try await loadKimi(key)
            guard !Task.isCancelled, accepts(request) else { return .superseded }
            // 保存失败不清除旧快照；先成功保存，才让请求期间的旧刷新失效并接纳。
            try store.saveKimiCodeKey(key)
            kimiGeneration &+= 1
            onKimiChanged(result)
            return .completed(result)
        } catch {
            guard !Task.isCancelled, accepts(request) else { return .superseded }
            throw error
        }
    }

    func connectZhipu(key input: String) async throws -> AccountQuotaConnectionOutcome<ZhipuQuotaResult> {
        guard permitsConnections() else { return .isolated }
        guard let key = normalized(input) else { throw CredentialStoreError.emptyCredential }
        zhipuGeneration &+= 1
        let request = zhipuRequest()
        if let error = request.credentialError { throw error }
        do {
            let result = try await loadZhipu(key, request.domain)
            guard !Task.isCancelled, accepts(request) else { return .superseded }
            try store.saveZhipuKey(key)
            zhipuGeneration &+= 1
            onZhipuChanged(result)
            return .completed(result)
        } catch {
            guard !Task.isCancelled, accepts(request) else { return .superseded }
            throw error
        }
    }

    func clearKimi() throws -> Bool {
        guard permitsConnections() else { return false }
        kimiGeneration &+= 1
        try store.clearKimiCodeKey()
        onKimiChanged(nil)
        return true
    }

    func clearZhipu() throws -> Bool {
        guard permitsConnections() else { return false }
        zhipuGeneration &+= 1
        try store.clearZhipuKey()
        onZhipuChanged(nil)
        return true
    }

    @discardableResult
    func setZhipuDomain(_ domain: ZhipuQuotaDomain) -> Bool {
        guard permitsConnections(), domain != store.zhipuQuotaDomain else { return false }
        zhipuGeneration &+= 1
        store.zhipuQuotaDomain = domain
        onZhipuChanged(nil)
        return true
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
