import Foundation

// 用户手填的 AI 订阅月费（Claude Max、ChatGPT Pro、Kimi 会员等）。只用于
// 总览 API 等价参考的回本倍数；只存本机 UserDefaults，不联网、不关联账号。
struct SubscriptionPlan: Codable, Equatable, Identifiable {
    static let currencies = ["USD", "CNY"]

    var id: UUID
    var name: String
    var monthlyFee: Double
    var currency: String

    init(id: UUID = UUID(), name: String = "", monthlyFee: Double = 0, currency: String = "USD") {
        self.id = id
        self.name = name
        self.monthlyFee = monthlyFee
        self.currency = currency
    }

    // 按固定参考汇率折算的美元月费；非正金额或无汇率的币种不计入
    var monthlyFeeUSD: Double? {
        guard monthlyFee.isFinite, monthlyFee > 0 else { return nil }
        if currency == "USD" { return monthlyFee }
        guard let rate = APIReferencePricingCatalog.conversionRatesToUSD[currency],
              rate > 0 else { return nil }
        return monthlyFee * rate
    }

    static func monthlyTotalUSD(_ plans: [SubscriptionPlan]) -> Double {
        plans.compactMap(\.monthlyFeeUSD).reduce(0, +)
    }
}

// 所选范围内的 API 等价金额 vs 同期订阅费：月费按年化折到天（× 12 / 365），
// 天数只算有模型明细的日子，避免拿没算进金额的天去摊订阅费。
struct SubscriptionValueSummary: Equatable {
    let monthlyFeeUSD: Double
    let days: Int
    let apiValueUSD: Double

    var proratedFeeUSD: Double { monthlyFeeUSD * 12 / 365 * Double(max(days, 0)) }

    var multiple: Double? {
        let fee = proratedFeeUSD
        guard fee > 0 else { return nil }
        return apiValueUSD / fee
    }
}
