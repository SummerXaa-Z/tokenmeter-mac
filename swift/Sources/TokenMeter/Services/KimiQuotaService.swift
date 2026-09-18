import Darwin
import Foundation

// Kimi Code 订阅配额有两条明确、只读的入口：
// 1. 用户在 TokenMeter 中主动配置 Kimi For Coding Key 后，查询官方 /usages；
// 2. 未配置 Key 时，尝试官方 CLI 的本机 Web 服务作为零配置兜底。
//
// 安全边界：
// - 官方查询固定为 https://api.kimi.com/coding/v1/usages；
// - 用户配置的 Key 只进 Authorization header，由 ConfigStore 存入 Keychain；
// - 只探测 ~/.kimi-code/server/instances/*.json 与 server.token；
// - 只向注册为 127.0.0.1 的存活实例发请求；
// - 不启动 daemon，不读取 Kimi/CC Switch/其他应用的私有凭据目录；
// - 本地 server token 仅用于当次 Authorization header，不写盘、不打印。

enum KimiQuotaUnit: String, Decodable, Equatable {
    case minute
    case hour
    case day
    case week
}

struct KimiQuotaWindow: Decodable, Equatable {
    let duration: Int
    let unit: KimiQuotaUnit
}

struct KimiQuotaRow: Equatable {
    let name: String?
    let window: KimiQuotaWindow?
    let used: Int
    let limit: Int
    let resetAt: String?

    // 统一成“剩余比例”口径；异常后端值会收敛到 0...1。
    var remaining: Double? {
        guard limit > 0 else { return nil }
        return min(max(Double(limit - used) / Double(limit), 0), 1)
    }

    var remainingPercent: Double? {
        remaining.map { $0 * 100 }
    }
}

struct KimiQuotaExtraUsage: Equatable {
    let balanceCents: Int
    let totalCents: Int
    let monthlyChargeLimitEnabled: Bool
    let monthlyChargeLimitCents: Int
    let monthlyUsedCents: Int
    let currency: String
}

enum KimiQuotaOrigin: Equatable {
    case officialAPI
    case localLoopback
}

struct KimiQuotaResult: Equatable {
    let summary: KimiQuotaRow?
    let limits: [KimiQuotaRow]
    let extraUsage: KimiQuotaExtraUsage?
    let origin: KimiQuotaOrigin

    init(
        summary: KimiQuotaRow?,
        limits: [KimiQuotaRow],
        extraUsage: KimiQuotaExtraUsage?,
        origin: KimiQuotaOrigin = .localLoopback
    ) {
        self.summary = summary
        self.limits = limits
        self.extraUsage = extraUsage
        self.origin = origin
    }
}

enum KimiQuotaError: LocalizedError, Equatable {
    case noRunningInstance
    case localServiceUnavailable
    case requestFailed
    case http(Int)
    case responseTooLarge
    case invalidResponse
    case providerUnavailable
    case officialAuthenticationFailed
    case officialEndpointUnavailable
    case officialRequestFailed
    case officialHTTP(Int)

    var errorDescription: String? {
        switch self {
        case .noRunningInstance:
            return "未配置 Kimi For Coding Key，且未发现 standalone kimi web 服务"
        case .localServiceUnavailable:
            return "Kimi Code 本地配额服务尚未就绪"
        case .requestFailed:
            return "无法连接 Kimi Code 本地配额服务"
        case .http(let status):
            return "Kimi Code 本地配额接口不可用（HTTP \(status)）"
        case .responseTooLarge:
            return "Kimi Code 配额响应超出安全上限"
        case .invalidResponse:
            return "Kimi Code 配额数据格式不受支持"
        case .providerUnavailable:
            return "Kimi Code 配额暂不可用"
        case .officialAuthenticationFailed:
            return "Kimi For Coding Key 已失效，请在设置中重新配置"
        case .officialEndpointUnavailable:
            return "当前 Key 不支持 Kimi For Coding 订阅额度查询"
        case .officialRequestFailed:
            return "无法连接 Kimi Code 官方额度接口"
        case .officialHTTP(let status):
            return "Kimi Code 官方额度接口不可用（HTTP \(status)）"
        }
    }

    // 只有网络、限流或服务端短暂故障可以短时保留 last-good。
    // 鉴权、端点、解析或本机服务消失都代表旧快照已不可信。
    var isTransient: Bool {
        switch self {
        case .requestFailed, .officialRequestFailed:
            return true
        case .http(let status), .officialHTTP(let status):
            return status == 429 || (500...599).contains(status)
        default:
            return false
        }
    }
}

protocol KimiQuotaHTTPClient {
    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse)
}

enum KimiQuotaTransportError: Error, Equatable {
    case invalidResponse
    case responseTooLarge
}

final class KimiQuotaURLSessionClient: KimiQuotaHTTPClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiQuotaTransportError.invalidResponse
        }
        if http.expectedContentLength > Int64(maximumResponseBytes) {
            throw KimiQuotaTransportError.responseTooLarge
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(http.expectedContentLength), maximumResponseBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw KimiQuotaTransportError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, http)
    }
}

struct KimiQuotaService {
    static let maximumInstanceFiles = 64
    static let maximumInstanceFileBytes = 16 * 1024
    static let maximumTokenFileBytes = 512
    static let maximumResponseBytes = 128 * 1024
    static let officialRequestTimeout: TimeInterval = 8
    static let officialUsageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    private let kimiCodeHome: URL
    private let fileManager: FileManager
    private let httpClient: KimiQuotaHTTPClient
    private let processIsAlive: (Int) -> Bool

    init(
        kimiCodeHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true),
        fileManager: FileManager = .default,
        httpClient: KimiQuotaHTTPClient = KimiQuotaURLSessionClient(),
        processIsAlive: @escaping (Int) -> Bool = KimiQuotaService.systemProcessIsAlive
    ) {
        self.kimiCodeHome = kimiCodeHome
        self.fileManager = fileManager
        self.httpClient = httpClient
        self.processIsAlive = processIsAlive
    }

    // 与 Kimi 官方 CLI、CC Switch 相同的云端查询入口。当前官方 schema 以
    // used/limit 为准，同时兼容旧版 remaining/limit；响应正文和底层错误绝不外泄。
    func load(apiKey: String) async throws -> KimiQuotaResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw KimiQuotaError.officialAuthenticationFailed }

        var request = URLRequest(
            url: Self.officialUsageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.officialRequestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await httpClient.data(
                for: request,
                maximumResponseBytes: Self.maximumResponseBytes
            )
            guard data.count <= Self.maximumResponseBytes else {
                throw KimiQuotaError.responseTooLarge
            }
            switch response.statusCode {
            case 200:
                return try Self.decodeOfficialResponse(data)
            case 401, 403:
                throw KimiQuotaError.officialAuthenticationFailed
            case 404:
                throw KimiQuotaError.officialEndpointUnavailable
            default:
                throw KimiQuotaError.officialHTTP(response.statusCode)
            }
        } catch let error as KimiQuotaError {
            throw error
        } catch KimiQuotaTransportError.responseTooLarge {
            throw KimiQuotaError.responseTooLarge
        } catch KimiQuotaTransportError.invalidResponse {
            throw KimiQuotaError.invalidResponse
        } catch {
            throw KimiQuotaError.officialRequestFailed
        }
    }

    func load() async throws -> KimiQuotaResult {
        let instances = try runningInstances()
        guard !instances.isEmpty else { throw KimiQuotaError.noRunningInstance }
        let token = try readServerToken()

        var lastError: KimiQuotaError = .requestFailed
        for instance in instances {
            guard let url = Self.usageURL(port: instance.port) else { continue }
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 3
            )
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await httpClient.data(
                    for: request,
                    maximumResponseBytes: Self.maximumResponseBytes
                )
                guard data.count <= Self.maximumResponseBytes else {
                    lastError = .responseTooLarge
                    continue
                }
                guard response.statusCode == 200 else {
                    lastError = .http(response.statusCode)
                    continue
                }
                return try Self.decodeResponse(data)
            } catch let error as KimiQuotaError {
                lastError = error
            } catch KimiQuotaTransportError.responseTooLarge {
                lastError = .responseTooLarge
            } catch KimiQuotaTransportError.invalidResponse {
                lastError = .invalidResponse
            } catch {
                // 不透传 URLSession、后端或响应正文中的原始错误。
                lastError = .requestFailed
            }
        }
        throw lastError
    }

    private func runningInstances() throws -> [Instance] {
        let directory = kimiCodeHome
            .appendingPathComponent("server", isDirectory: true)
            .appendingPathComponent("instances", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            )
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT) {
                return []
            }
            throw KimiQuotaError.localServiceUnavailable
        }

        var instances: [Instance] = []
        let candidates = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.maximumInstanceFiles)
        for file in candidates {
            guard let data = try? boundedFileData(
                at: file,
                maximumBytes: Self.maximumInstanceFileBytes
            ), let instance = Self.decodeInstance(data),
                  instance.host == "127.0.0.1",
                  (1...65_535).contains(instance.port),
                  processIsAlive(instance.pid)
            else { continue }
            instances.append(instance)
        }

        instances.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.port < $1.port
        }
        var seenPorts = Set<Int>()
        return instances.filter { seenPorts.insert($0.port).inserted }
    }

    private func readServerToken() throws -> String {
        let url = kimiCodeHome.appendingPathComponent("server.token")
        let data: Data
        do {
            data = try boundedFileData(at: url, maximumBytes: Self.maximumTokenFileBytes)
        } catch {
            throw KimiQuotaError.localServiceUnavailable
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw KimiQuotaError.localServiceUnavailable
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            throw KimiQuotaError.localServiceUnavailable
        }
        return token
    }

    private func boundedFileData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumBytes
        else {
            throw KimiQuotaError.localServiceUnavailable
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw KimiQuotaError.localServiceUnavailable
        }
        return data
    }

    static func usageURL(port: Int) -> URL? {
        guard (1...65_535).contains(port) else { return nil }
        return URL(
            string: "http://127.0.0.1:\(port)/api/v1/oauth/usage"
                + "?provider=managed%3Akimi-code"
        )
    }

    static func decodeInstance(_ data: Data) -> Instance? {
        guard data.count <= maximumInstanceFileBytes,
              let instance = try? JSONDecoder().decode(Instance.self, from: data),
              !instance.serverID.isEmpty,
              instance.pid > 0,
              instance.startedAt.isFinite,
              instance.heartbeatAt.isFinite
        else { return nil }
        return instance
    }

    static func decodeResponse(_ data: Data) throws -> KimiQuotaResult {
        guard data.count <= maximumResponseBytes else {
            throw KimiQuotaError.responseTooLarge
        }
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw KimiQuotaError.invalidResponse
        }
        guard envelope.code == 0, let payload = envelope.data else {
            throw KimiQuotaError.providerUnavailable
        }
        guard payload.kind == "ok" else {
            throw payload.kind == "error"
                ? KimiQuotaError.providerUnavailable
                : KimiQuotaError.invalidResponse
        }

        return KimiQuotaResult(
            summary: payload.summary.map(Self.row),
            limits: payload.limits.map(Self.row),
            extraUsage: payload.extraUsage.map {
                KimiQuotaExtraUsage(
                    balanceCents: $0.balanceCents,
                    totalCents: $0.totalCents,
                    monthlyChargeLimitEnabled: $0.monthlyChargeLimitEnabled,
                    monthlyChargeLimitCents: $0.monthlyChargeLimitCents,
                    monthlyUsedCents: $0.monthlyUsedCents,
                    currency: $0.currency
                )
            }
        )
    }

    // Kimi 官方 /usages 返回裸对象，不是本机 Web 服务的 code/data 包络。
    // 解析规则以 Moonshot 官方 managed-usage.ts 为准，并兼容 CC Switch 仍使用的
    // remaining 字段以及数字型 resetTime。
    static func decodeOfficialResponse(_ data: Data) throws -> KimiQuotaResult {
        guard data.count <= maximumResponseBytes else {
            throw KimiQuotaError.responseTooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw KimiQuotaError.invalidResponse
        }
        guard let root = object as? [String: Any] else {
            throw KimiQuotaError.invalidResponse
        }

        let weeklyWindow = KimiQuotaWindow(duration: 1, unit: .week)
        let summary = (root["usage"] as? [String: Any]).flatMap {
            officialRow(
                $0,
                name: nonemptyString($0["name"]),
                window: weeklyWindow
            )
        }

        var limits: [KimiQuotaRow] = []
        if let items = root["limits"] as? [Any] {
            for value in items {
                guard let item = value as? [String: Any],
                      let detail = item["detail"] as? [String: Any]
                else { continue }
                let name = nonemptyString(item["name"])
                    ?? nonemptyString(detail["name"])
                if let row = officialRow(
                    detail,
                    name: name,
                    window: officialWindow(item["window"])
                ) {
                    limits.append(row)
                }
            }
        }

        let extraUsage = officialExtraUsage(root["boosterWallet"])
        guard summary != nil || !limits.isEmpty || extraUsage != nil else {
            throw KimiQuotaError.providerUnavailable
        }
        return KimiQuotaResult(
            summary: summary,
            limits: limits,
            extraUsage: extraUsage,
            origin: .officialAPI
        )
    }

    private static func officialRow(
        _ raw: [String: Any],
        name: String?,
        window: KimiQuotaWindow?
    ) -> KimiQuotaRow? {
        let explicitUsed = integer(raw["used"])
        let limitValue = integer(raw["limit"])
        let remainingValue = integer(raw["remaining"])
        guard explicitUsed != nil || limitValue != nil
            || (remainingValue != nil && limitValue != nil)
        else { return nil }

        let limit = max(limitValue ?? 0, 0)
        // Moonshot 当前官方 schema 以 used 为准；只在 used 缺失时
        // 才用 CC Switch 旧形态的 remaining 回推，避免过渡期冲突字段盖过官方值。
        let used: Int
        if let explicitUsed {
            used = max(explicitUsed, 0)
        } else if let remainingValue, limitValue != nil {
            used = max(limit - remainingValue, 0)
        } else {
            used = 0
        }
        return KimiQuotaRow(
            name: name,
            window: window,
            used: used,
            limit: limit,
            resetAt: resetAt(raw["resetTime"])
        )
    }

    private static func officialWindow(_ value: Any?) -> KimiQuotaWindow? {
        guard let raw = value as? [String: Any],
              let durationValue = integer(raw["duration"]), durationValue > 0,
              let timeUnit = raw["timeUnit"] as? String
        else { return nil }
        let unit: KimiQuotaUnit
        switch timeUnit {
        case "TIME_UNIT_MINUTE": unit = .minute
        case "TIME_UNIT_HOUR": unit = .hour
        case "TIME_UNIT_DAY": unit = .day
        case "TIME_UNIT_WEEK": unit = .week
        default: return nil
        }
        if unit == .minute, durationValue >= 60, durationValue % 60 == 0 {
            return KimiQuotaWindow(duration: durationValue / 60, unit: .hour)
        }
        return KimiQuotaWindow(duration: durationValue, unit: unit)
    }

    private static func officialExtraUsage(_ value: Any?) -> KimiQuotaExtraUsage? {
        guard let wallet = value as? [String: Any],
              let balance = wallet["balance"] as? [String: Any],
              balance["type"] as? String == "BOOSTER",
              let amount = integer(balance["amount"]), amount > 0
        else { return nil }

        let monthlyLimit = money(wallet["monthlyChargeLimit"])
        let monthlyUsed = money(wallet["monthlyUsed"])
        let currency = nonemptyString(monthlyLimit?.currency)
            ?? nonemptyString(monthlyUsed?.currency)
            ?? "USD"
        return KimiQuotaExtraUsage(
            balanceCents: fixedPointToCents(integer(balance["amountLeft"])),
            totalCents: fixedPointToCents(amount),
            monthlyChargeLimitEnabled: wallet["monthlyChargeLimitEnabled"] as? Bool == true,
            monthlyChargeLimitCents: max(monthlyLimit?.cents ?? 0, 0),
            monthlyUsedCents: max(monthlyUsed?.cents ?? 0, 0),
            currency: currency
        )
    }

    private static func money(_ value: Any?) -> (cents: Int, currency: String)? {
        guard let raw = value as? [String: Any],
              let cents = integer(raw["priceInCents"])
        else { return nil }
        return (cents, nonemptyString(raw["currency"]) ?? "")
    }

    // boosterWallet.balance 的 amount/amountLeft 是 1,000,000 fixed-point
    // units / cent；月上限字段已经是整 cents，不能复用此转换。
    private static func fixedPointToCents(_ value: Int?) -> Int {
        guard let value, value > 0 else { return 0 }
        let scale = 1_000_000
        let whole = value / scale
        let remainder = value % scale
        return max(whole + (remainder >= scale / 2 ? 1 : 0), 1)
    }

    private static func resetAt(_ value: Any?) -> String? {
        if let string = nonemptyString(value) { return string }
        guard let raw = integer(value), raw > 0 else { return nil }
        let seconds = raw < 1_000_000_000_000
            ? TimeInterval(raw)
            : TimeInterval(raw) / 1_000
        guard seconds.isFinite, seconds > 0 else { return nil }
        return officialResetFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite,
                  double >= Double(Int.min), double <= Double(Int.max)
            else { return nil }
            return Int(double.rounded(.towardZero))
        }
        guard let string = nonemptyString(value),
              let double = Double(string), double.isFinite,
              double >= Double(Int.min), double <= Double(Int.max)
        else { return nil }
        return Int(double.rounded(.towardZero))
    }

    private static let officialResetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func row(_ wire: WireRow) -> KimiQuotaRow {
        KimiQuotaRow(
            name: wire.name,
            window: wire.window,
            used: wire.used,
            limit: wire.limit,
            resetAt: wire.resetAt
        )
    }

    private static func systemProcessIsAlive(_ pid: Int) -> Bool {
        guard let value = Int32(exactly: pid), value > 0 else { return false }
        if Darwin.kill(value, 0) == 0 { return true }
        return errno == EPERM
    }

    struct Instance: Decodable, Equatable {
        let serverID: String
        let pid: Int
        let host: String
        let port: Int
        let startedAt: Double
        let heartbeatAt: Double

        enum CodingKeys: String, CodingKey {
            case serverID = "server_id"
            case pid
            case host
            case port
            case startedAt = "started_at"
            case heartbeatAt = "heartbeat_at"
        }
    }

    private struct ResponseEnvelope: Decodable {
        let code: Int
        let data: WirePayload?
    }

    private struct WirePayload: Decodable {
        let kind: String
        let summary: WireRow?
        let limits: [WireRow]
        let extraUsage: WireExtraUsage?

        enum CodingKeys: String, CodingKey {
            case kind
            case summary
            case limits
            case extraUsage = "extra_usage"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            summary = try container.decodeIfPresent(WireRow.self, forKey: .summary)
            limits = try container.decodeIfPresent([WireRow].self, forKey: .limits) ?? []
            extraUsage = try container.decodeIfPresent(WireExtraUsage.self, forKey: .extraUsage)
        }
    }

    private struct WireRow: Decodable {
        let name: String?
        let window: KimiQuotaWindow?
        let used: Int
        let limit: Int
        let resetAt: String?

        enum CodingKeys: String, CodingKey {
            case name
            case window
            case used
            case limit
            case resetAt = "reset_at"
        }
    }

    private struct WireExtraUsage: Decodable {
        let balanceCents: Int
        let totalCents: Int
        let monthlyChargeLimitEnabled: Bool
        let monthlyChargeLimitCents: Int
        let monthlyUsedCents: Int
        let currency: String

        enum CodingKeys: String, CodingKey {
            case balanceCents = "balance_cents"
            case totalCents = "total_cents"
            case monthlyChargeLimitEnabled = "monthly_charge_limit_enabled"
            case monthlyChargeLimitCents = "monthly_charge_limit_cents"
            case monthlyUsedCents = "monthly_used_cents"
            case currency
        }
    }
}
