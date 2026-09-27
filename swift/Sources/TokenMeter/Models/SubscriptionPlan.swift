import Foundation

// 用户手填的 AI 订阅月费（Claude Max、ChatGPT Pro、Kimi 会员等）。只用于
// API 等价参考的回本倍数；只存本机 UserDefaults，不联网、不关联账号。
// source 为订阅的归属来源：指定后该来源详情页的 API 等价卡同步显示回本
// 倍数；不指定（nil）只计入总览。总览始终计入全部订阅。
struct SubscriptionPlan: Codable, Equatable, Identifiable {
    static let currencies = ["USD", "CNY"]

    var id: UUID
    var name: String
    var monthlyFee: Double
    var currency: String
    // Optional 让旧版 JSON（无此键）解码为 nil，老数据无需迁移
    var source: HistorySource?

    init(
        id: UUID = UUID(), name: String = "", monthlyFee: Double = 0,
        currency: String = "USD", source: HistorySource? = nil
    ) {
        self.id = id
        self.name = name
        self.monthlyFee = monthlyFee
        self.currency = currency
        self.source = source
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

    /// 归属到某来源的订阅月费合计（来源页回本倍数的分母）。
    static func monthlyTotalUSD(_ plans: [SubscriptionPlan], tagged source: HistorySource) -> Double {
        plans.filter { $0.source == source }.compactMap(\.monthlyFeeUSD).reduce(0, +)
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

    static func multipleText(_ multiple: Double) -> String {
        if multiple >= 10 { return String(format: "约 %.0f 倍", multiple) }
        return String(format: "约 %.1f 倍", multiple)
    }

    var detailText: String {
        var text = "订阅月费 \(Fmt.usd(monthlyFeeUSD)) · 按 \(days) 天折算 \(Fmt.usd(proratedFeeUSD))"
        if let multiple, multiple < 1 {
            text += "；低于 1 倍表示按 API 用量付费会更省。"
        }
        return text
    }
}
