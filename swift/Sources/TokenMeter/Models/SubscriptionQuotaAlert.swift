import Foundation

// 订阅额度告警的纯函数层：从 Kimi / 智谱 / 火山方舟的配额结果里取"最坏剩余
// 百分比"，并给出与 Codex 配额告警一致的通知线（≤10%）与图标染色线
// （≤30% 橙、≤10% 红）。每个提供方的全部窗口（含智谱工具调用次数额度、
// 方舟全部已订阅套餐的全部周期）都参与最坏值——任何一个窗口耗尽都阻断
// 使用。无任何可用窗口时返回 nil，表示本轮不评估。
enum SubscriptionQuotaAlert {
    static func codexWorstRemainingPercent(_ result: CodexRateLimits, now: Date = Date()) -> Double? {
        worst(SubscriptionQuotaSnapshot(codex: result, now: now))
    }

    static func kimiWorstRemainingPercent(_ result: KimiQuotaResult, now: Date = Date()) -> Double? {
        worst(SubscriptionQuotaSnapshot(kimi: result, now: now))
    }

    static func zhipuWorstRemainingPercent(_ result: ZhipuQuotaResult, now: Date = Date()) -> Double? {
        worst(SubscriptionQuotaSnapshot(zhipu: result, now: now))
    }

    static func arkWorstRemainingPercent(_ result: ArkPlanQuotaSnapshot, now: Date = Date()) -> Double? {
        worst(SubscriptionQuotaSnapshot(ark: result, now: now))
    }

    private static func worst(_ snapshot: SubscriptionQuotaSnapshot) -> Double? {
        snapshot.groups.flatMap(\.periods)
            .compactMap(\.remainingPercent)
            .min()
    }

    static func shouldNotify(remainingPercent: Double?) -> Bool {
        guard let remainingPercent, remainingPercent.isFinite else { return false }
        return remainingPercent <= 10
    }

    static func isWarn(_ remaining: Double) -> Bool {
        remaining <= 30
    }

    static func isCritical(_ remaining: Double) -> Bool {
        remaining <= 10
    }
}
