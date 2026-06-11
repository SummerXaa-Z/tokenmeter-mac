import Foundation

// DeepSeek 官方余额接口返回结构
struct BalanceInfo: Decodable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

struct BalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

// 面板使用的余额视图模型
struct Balance: Equatable {
    let isAvailable: Bool
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    var symbol: String { currency == "USD" ? "$" : "¥" }
}

// 单模型用量汇总
struct UsageModelSummary: Equatable, Identifiable {
    let key: String          // "flash" | "pro"
    let name: String         // "V4 Flash" | "V4 Pro"
    let totalTokens: Int
    let requestCount: Int
    let cacheHitTokens: Int
    let cacheMissTokens: Int
    let responseTokens: Int
    let cost: Double

    var id: String { key }

    var cacheHitRate: Double? {
        let denom = cacheHitTokens + cacheMissTokens
        guard denom > 0 else { return nil }
        return Double(cacheHitTokens) / Double(denom) * 100
    }
}

// 单日用量
struct UsageDay: Equatable, Identifiable {
    let date: String         // "YYYY-MM-DD"
    let flashTokens: Int
    let flashCacheHit: Int
    let flashCacheMiss: Int
    let flashResponse: Int
    let proTokens: Int
    let proCacheHit: Int
    let proCacheMiss: Int
    let proResponse: Int
    let totalTokens: Int
    let totalCost: Double

    var id: String { date }

    static func empty(_ date: String) -> UsageDay {
        UsageDay(date: date, flashTokens: 0, flashCacheHit: 0, flashCacheMiss: 0,
                 flashResponse: 0, proTokens: 0, proCacheHit: 0, proCacheMiss: 0,
                 proResponse: 0, totalTokens: 0, totalCost: 0)
    }
}

// 一次用量查询的完整结果
struct UsageResult: Equatable {
    let models: [UsageModelSummary]
    let days: [UsageDay]
    let monthCost: Double

    func model(_ key: String) -> UsageModelSummary? {
        models.first { $0.key == key }
    }
}

// 加载状态机，对应原版 BalanceState
enum LoadState: Equatable {
    case loading
    case ok
    case error(String)
    case noKey
}
