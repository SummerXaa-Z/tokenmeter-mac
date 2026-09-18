import Foundation

// 智谱 GLM Coding Plan 订阅配额查询（只读）。
//
// 安全边界：
// - 仅请求用户所选域名的官方监控接口（国内 open.bigmodel.cn / 国际 api.z.ai）；
// - 用户配置的 API Key 只进 Authorization header（智谱该接口鉴权不加 Bearer
//   前缀），由 ConfigStore 存入 Keychain，不写盘、不打印；
// - 响应正文和底层错误绝不外泄到错误文案；
// - 该接口为智谱控制台使用的未公开文档接口，结构可能变化，解析失败按
//   providerUnavailable 降级，不猜测字段含义。

enum ZhipuQuotaError: LocalizedError, Equatable {
    case authenticationFailed
    case requestFailed
    case responseTooLarge
    case invalidResponse
    case providerUnavailable
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "智谱 API Key 已失效，请在设置中重新配置"
        case .requestFailed:
            return "无法连接智谱额度接口"
        case .responseTooLarge:
            return "智谱配额响应超出安全上限"
        case .invalidResponse:
            return "智谱配额数据格式不受支持"
        case .providerUnavailable:
            return "智谱配额暂不可用"
        case .http(let status):
            return "智谱额度接口不可用（HTTP \(status)）"
        }
    }

    // 只有网络、限流或服务端短暂故障可以短时保留 last-good。
    // 鉴权、解析或结构变化都代表旧快照已不可信。
    var isTransient: Bool {
        switch self {
        case .requestFailed:
            return true
        case .http(let status):
            return status == 429 || (500...599).contains(status)
        default:
            return false
        }
    }
}

// 单个额度窗口。智谱的 percentage 口径是“已用百分比”，UI 侧再换算剩余。
struct ZhipuQuotaTier: Equatable {
    let usedPercent: Double
    // currentValue / usage 是绝对量（token 数或工具调用次数），缺失时为 nil。
    let used: Double?
    let total: Double?
    let resetAt: Date?
}

struct ZhipuQuotaResult: Equatable {
    let fiveHour: ZhipuQuotaTier?
    let weekly: ZhipuQuotaTier?
    // TIME_LIMIT：MCP 工具调用的月度次数额度，仅部分套餐返回。
    let toolCalls: ZhipuQuotaTier?
    // 套餐档位（lite / pro / max 等），可能缺失。
    let level: String?

    init(
        fiveHour: ZhipuQuotaTier?,
        weekly: ZhipuQuotaTier?,
        toolCalls: ZhipuQuotaTier? = nil,
        level: String? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.toolCalls = toolCalls
        self.level = level
    }

    var windowCount: Int {
        [fiveHour, weekly, toolCalls].compactMap { $0 }.count
    }
}

// 智谱分国内站与国际站，两套账号体系，但配额接口路径与响应结构一致。
enum ZhipuQuotaDomain: String, Equatable, CaseIterable {
    case china
    case international

    var baseURL: URL {
        switch self {
        case .china:
            return URL(string: "https://open.bigmodel.cn")!
        case .international:
            return URL(string: "https://api.z.ai")!
        }
    }

    var title: String {
        switch self {
        case .china:
            return "国内版"
        case .international:
            return "国际版"
        }
    }
}

protocol ZhipuQuotaHTTPClient {
    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse)
}

enum ZhipuQuotaTransportError: Error, Equatable {
    case invalidResponse
    case responseTooLarge
}

final class ZhipuQuotaURLSessionClient: ZhipuQuotaHTTPClient {
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
            throw ZhipuQuotaTransportError.invalidResponse
        }
        if http.expectedContentLength > Int64(maximumResponseBytes) {
            throw ZhipuQuotaTransportError.responseTooLarge
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(http.expectedContentLength), maximumResponseBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw ZhipuQuotaTransportError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, http)
    }
}

struct ZhipuQuotaService {
    static let maximumResponseBytes = 128 * 1024
    static let requestTimeout: TimeInterval = 8

    private let httpClient: ZhipuQuotaHTTPClient

    init(httpClient: ZhipuQuotaHTTPClient = ZhipuQuotaURLSessionClient()) {
        self.httpClient = httpClient
    }

    static func quotaURL(for domain: ZhipuQuotaDomain) -> URL {
        domain.baseURL.appendingPathComponent("api/monitor/usage/quota/limit")
    }

    // 与智谱控制台一致的用量查询入口；响应正文和底层错误绝不外泄。
    func load(
        apiKey: String,
        domain: ZhipuQuotaDomain = .china
    ) async throws -> ZhipuQuotaResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw ZhipuQuotaError.authenticationFailed }

        var request = URLRequest(
            url: Self.quotaURL(for: domain),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 智谱该接口的鉴权是裸 API Key，不加 Bearer 前缀（与官方控制台一致）。
        request.setValue(key, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await httpClient.data(
                for: request,
                maximumResponseBytes: Self.maximumResponseBytes
            )
            guard data.count <= Self.maximumResponseBytes else {
                throw ZhipuQuotaError.responseTooLarge
            }
            switch response.statusCode {
            case 200:
                return try Self.decodeResponse(data)
            case 401, 403:
                throw ZhipuQuotaError.authenticationFailed
            default:
                throw ZhipuQuotaError.http(response.statusCode)
            }
        } catch let error as ZhipuQuotaError {
            throw error
        } catch ZhipuQuotaTransportError.responseTooLarge {
            throw ZhipuQuotaError.responseTooLarge
        } catch ZhipuQuotaTransportError.invalidResponse {
            throw ZhipuQuotaError.invalidResponse
        } catch {
            throw ZhipuQuotaError.requestFailed
        }
    }

    // 解析规则以智谱控制台响应实测形态为准（与 CC Switch 生产实现交叉验证）：
    // - limits[] 的 type 大小写不敏感地兼容 TOKENS_LIMIT 与 CREDIT_LIMIT（上游改过名）；
    // - 窗口分类锚定 unit 字段（3 = 5 小时、6 = 每周），不能按 nextResetTime
    //   排序代替——周期末尾每周桶会比 5 小时桶更早重置，时间排序必然标反；
    // - unit 缺失/不识别时兜底：无 nextResetTime 的条目优先归 5 小时槽位
    //   （5 小时桶在 0% 等状态下可能没有 reset），其余按重置时间升序补入空槽；
    // - TIME_LIMIT 是 MCP 工具调用的月度次数额度；
    // - nextResetTime 为毫秒 epoch。
    static func decodeResponse(_ data: Data) throws -> ZhipuQuotaResult {
        guard data.count <= maximumResponseBytes else {
            throw ZhipuQuotaError.responseTooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ZhipuQuotaError.invalidResponse
        }
        guard let root = object as? [String: Any] else {
            throw ZhipuQuotaError.invalidResponse
        }

        // 业务级错误：success == false 时 msg 为服务端文案，不透传原文。
        if root["success"] as? Bool == false {
            throw ZhipuQuotaError.providerUnavailable
        }
        guard let payload = root["data"] as? [String: Any] else {
            throw ZhipuQuotaError.providerUnavailable
        }

        let level = nonemptyString(payload["level"])
        var fiveHour: ZhipuQuotaTier?
        var weekly: ZhipuQuotaTier?
        var toolCalls: ZhipuQuotaTier?
        var unclassified: [ZhipuQuotaTier] = []

        for value in payload["limits"] as? [Any] ?? [] {
            guard let item = value as? [String: Any] else { continue }
            let type = nonemptyString(item["type"])?.uppercased() ?? ""
            if type == "TIME_LIMIT" {
                if toolCalls == nil { toolCalls = tier(item) }
                continue
            }
            guard type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" else { continue }
            guard let entry = tier(item) else { continue }
            let unit = integer(item["unit"])
            if unit == 3, fiveHour == nil {
                fiveHour = entry
            } else if unit == 6, weekly == nil {
                weekly = entry
            } else {
                unclassified.append(entry)
            }
        }

        for entry in unclassified.sorted(by: resetAscending) {
            if fiveHour == nil {
                fiveHour = entry
            } else if weekly == nil {
                weekly = entry
            }
            // 智谱当前最多两条 token 窗口，多余的忽略
        }

        guard fiveHour != nil || weekly != nil || toolCalls != nil || level != nil else {
            throw ZhipuQuotaError.providerUnavailable
        }
        return ZhipuQuotaResult(
            fiveHour: fiveHour,
            weekly: weekly,
            toolCalls: toolCalls,
            level: level
        )
    }

    // 无 reset 的排最前（优先归 5 小时槽位），其余按重置时间升序。
    private static func resetAscending(
        _ lhs: ZhipuQuotaTier,
        _ rhs: ZhipuQuotaTier
    ) -> Bool {
        switch (lhs.resetAt, rhs.resetAt) {
        case (nil, nil):
            return false
        case (nil, _):
            return true
        case (_, nil):
            return false
        case (let left?, let right?):
            return left < right
        }
    }

    private static func tier(_ item: [String: Any]) -> ZhipuQuotaTier? {
        let usedValue = double(item["currentValue"])
        let totalValue = double(item["usage"])
        var percentage = double(item["percentage"])
        if percentage == nil, let used = usedValue, let total = totalValue, total > 0 {
            percentage = used / total * 100
        }
        guard let percentage, percentage.isFinite else { return nil }
        return ZhipuQuotaTier(
            usedPercent: min(max(percentage, 0), 100),
            used: usedValue.flatMap { $0 >= 0 ? $0 : nil },
            total: totalValue.flatMap { $0 > 0 ? $0 : nil },
            resetAt: resetDate(item["nextResetTime"])
        )
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = integer(value), raw > 0 else { return nil }
        // nextResetTime 为毫秒 epoch；兼容秒级回退。
        let seconds = raw < 1_000_000_000_000
            ? TimeInterval(raw)
            : TimeInterval(raw) / 1_000
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
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

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        guard let string = nonemptyString(value),
              let double = Double(string), double.isFinite
        else { return nil }
        return double
    }
}
