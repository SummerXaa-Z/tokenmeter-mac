import Foundation

enum APIError: LocalizedError {
    case noKey
    case noToken
    case unauthorized
    case rateLimited
    case server(Int)
    case http(Int)
    case network(String)
    case decode(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noKey: return "未配置 API Key"
        case .noToken: return "未配置用量 Token"
        case .unauthorized: return "API Key 无效或已过期"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .server(let c): return "DeepSeek 服务器错误：\(c)"
        case .http(let c): return "请求失败：HTTP \(c)"
        case .network(let m): return "网络请求失败：\(m)"
        case .decode(let m): return "解析数据失败：\(m)"
        case .empty: return "返回数据为空"
        }
    }
}

// 平台内部用量接口的原始解码结构（对应 Rust fetch_usage 里的内嵌 struct）
private struct UsageEntry: Decodable {
    let type: String
    let amount: String
}
private struct ModelUsage: Decodable {
    let model: String
    let usage: [UsageEntry]
}
private struct DayUsage: Decodable {
    let date: String
    let data: [ModelUsage]
}
private struct AmountBiz: Decodable {
    let total: [ModelUsage]
    let days: [DayUsage]
}
private struct AmountData: Decodable { let biz_data: AmountBiz }
private struct AmountResp: Decodable { let data: AmountData }
private struct CostBiz: Decodable {
    let total: [ModelUsage]
    let days: [DayUsage]
}
private struct CostData: Decodable { let biz_data: [CostBiz] }
private struct CostResp: Decodable { let data: CostData }

struct DeepSeekAPI {
    static let macUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

    private static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }

    // MARK: - 余额（官方 API Key）

    static func fetchBalance(apiKey: String) async throws -> Balance {
        guard !apiKey.isEmpty else { throw APIError.noKey }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session().data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401: throw APIError.unauthorized
        case 429: throw APIError.rateLimited
        case let c where c >= 500: throw APIError.server(c)
        default: throw APIError.http(code)
        }

        let parsed: BalanceResponse
        do {
            parsed = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw APIError.decode(error.localizedDescription)
        }
        guard let info = parsed.balanceInfos.first else { throw APIError.empty }
        return Balance(isAvailable: parsed.isAvailable, currency: info.currency,
                       totalBalance: info.totalBalance, grantedBalance: info.grantedBalance,
                       toppedUpBalance: info.toppedUpBalance)
    }

    // MARK: - 用量（网页登录 token，非 API Key）

    private static func getJSON<T: Decodable>(_ type: T.Type, url: String, token: String) async throws -> T {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("1.0.0", forHTTPHeaderField: "x-app-version")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(macUA, forHTTPHeaderField: "User-Agent")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session().data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401: throw APIError.unauthorized
        case 429: throw APIError.rateLimited
        default: throw APIError.http(code)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decode(error.localizedDescription)
        }
    }

    // 验证 token 真能调用用量接口
    static func verifyUsageToken(_ token: String, month: Int, year: Int) async -> Bool {
        let url = "https://platform.deepseek.com/api/v0/usage/amount?month=\(month)&year=\(year)"
        do {
            _ = try await getJSON(AmountResp.self, url: url, token: token)
            return true
        } catch {
            return false
        }
    }

    // 返回 (总token, 请求数, 命中, 未命中, 输出)，对应 Rust token_breakdown。
    // DeepSeek 口径 prompt_token = cache_hit + cache_miss（输入侧的两种细分）。
    // 三类若同时返回，不能各自累加进 total——否则输入侧翻倍。这里输入侧只取
    // 一次：有 hit/miss 细分就用其和，没有才退回 prompt_token；输出侧单独加。
    private static func tokenBreakdown(_ usage: [UsageEntry]) -> (Int, Int, Int, Int, Int) {
        var request = 0, hit = 0, miss = 0, response = 0, prompt = 0
        for e in usage {
            let v = Int((Double(e.amount) ?? 0).rounded())
            switch e.type {
            case "REQUEST": request = v
            case "PROMPT_CACHE_HIT_TOKEN": hit = v
            case "PROMPT_CACHE_MISS_TOKEN": miss = v
            case "RESPONSE_TOKEN": response = v
            case "PROMPT_TOKEN": prompt = v
            default: break
            }
        }
        let inputSide = (hit + miss) > 0 ? hit + miss : prompt
        return (inputSide + response, request, hit, miss, response)
    }

    private static func costSum(_ usage: [UsageEntry]) -> Double {
        usage.filter { $0.type != "REQUEST" }
            .compactMap { Double($0.amount) }
            .reduce(0, +)
    }

    static func fetchUsage(token: String, month: Int, year: Int) async throws -> UsageResult {
        guard !token.isEmpty else { throw APIError.noToken }
        let amountURL = "https://platform.deepseek.com/api/v0/usage/amount?month=\(month)&year=\(year)"
        let costURL = "https://platform.deepseek.com/api/v0/usage/cost?month=\(month)&year=\(year)"

        let amount = try await getJSON(AmountResp.self, url: amountURL, token: token)
        let cost = try await getJSON(CostResp.self, url: costURL, token: token)

        let costTotal = cost.data.biz_data.first
        func costForModel(_ model: String) -> Double {
            guard let m = costTotal?.total.first(where: { $0.model == model }) else { return 0 }
            return costSum(m.usage)
        }

        var models: [UsageModelSummary] = []
        for mu in amount.data.biz_data.total {
            let label: (String, String)?
            switch mu.model {
            case "deepseek-v4-flash": label = ("flash", "V4 Flash")
            case "deepseek-v4-pro": label = ("pro", "V4 Pro")
            default: label = nil
            }
            guard let (key, name) = label else { continue }
            let (total, request, hit, miss, response) = tokenBreakdown(mu.usage)
            models.append(UsageModelSummary(
                key: key, name: name, totalTokens: total, requestCount: request,
                cacheHitTokens: hit, cacheMissTokens: miss, responseTokens: response,
                cost: costForModel(mu.model)))
        }

        var costByDate: [String: Double] = [:]
        if let item = costTotal {
            for day in item.days {
                costByDate[day.date] = day.data.map { costSum($0.usage) }.reduce(0, +)
            }
        }

        var days: [UsageDay] = []
        for day in amount.data.biz_data.days {
            var flash = 0, fHit = 0, fMiss = 0, fResp = 0
            var pro = 0, pHit = 0, pMiss = 0, pResp = 0
            var total = 0
            for mu in day.data {
                let (tokens, _, hit, miss, response) = tokenBreakdown(mu.usage)
                total += tokens
                switch mu.model {
                case "deepseek-v4-flash": flash += tokens; fHit += hit; fMiss += miss; fResp += response
                case "deepseek-v4-pro": pro += tokens; pHit += hit; pMiss += miss; pResp += response
                default: break
                }
            }
            days.append(UsageDay(
                date: day.date, flashTokens: flash, flashCacheHit: fHit, flashCacheMiss: fMiss,
                flashResponse: fResp, proTokens: pro, proCacheHit: pHit, proCacheMiss: pMiss,
                proResponse: pResp, totalTokens: total, totalCost: costByDate[day.date] ?? 0))
        }

        let monthCost = costTotal.map { $0.total.map { costSum($0.usage) }.reduce(0, +) } ?? 0
        return UsageResult(models: models, days: days, monthCost: monthCost)
    }
}
