import Foundation

enum SubscriptionQuotaSource: String, Equatable {
    case codex
    case kimiCode
    case ark
}

struct SubscriptionQuotaPeriod: Equatable, Identifiable {
    let id: String
    let label: String
    let remainingPercent: Double?
    let resetAt: Date?
    let detail: String?
}

struct SubscriptionQuotaExtraUsage: Equatable {
    let balanceCents: Int
    let totalCents: Int
    let monthlyChargeLimitEnabled: Bool
    let monthlyChargeLimitCents: Int
    let monthlyUsedCents: Int
    let currency: String
}

struct SubscriptionQuotaGroup: Equatable, Identifiable {
    let id: String
    let source: SubscriptionQuotaSource
    let title: String
    let subtitle: String?
    let periods: [SubscriptionQuotaPeriod]
    let extraUsage: SubscriptionQuotaExtraUsage?
}

// 将各订阅源不同的配额结构归一为 UI 可直接平铺的 group / period。
// 加载失败、未登录等状态仍由 AppState/UI 各自维护，不混入纯数据模型。
struct SubscriptionQuotaSnapshot: Equatable {
    let groups: [SubscriptionQuotaGroup]

    init(
        codex: CodexRateLimits? = nil,
        kimi: KimiQuotaResult? = nil,
        ark: ArkPlanQuotaSnapshot? = nil
    ) {
        var result: [SubscriptionQuotaGroup] = []
        if let codexGroup = Self.codexGroup(codex) { result.append(codexGroup) }
        if let kimi { result.append(Self.kimiGroup(kimi)) }
        result.append(contentsOf: Self.arkGroups(ark))
        groups = result
    }

    private static func codexGroup(_ limits: CodexRateLimits?) -> SubscriptionQuotaGroup? {
        // additional_rate_limits 是灰度/实验通道；订阅总览只接主 codex 通道。
        guard let limits, limits.isMain else { return nil }
        var periods: [SubscriptionQuotaPeriod] = []
        if let primary = limits.primary {
            periods.append(SubscriptionQuotaPeriod(
                id: "codex:subscription:primary",
                label: label(windowMinutes: primary.windowMinutes),
                remainingPercent: remaining(fromUsedPercent: primary.usedPercent),
                resetAt: validResetDate(primary.resetsAt),
                detail: nil
            ))
        }
        if let secondary = limits.secondary {
            periods.append(SubscriptionQuotaPeriod(
                id: "codex:subscription:secondary",
                label: label(windowMinutes: secondary.windowMinutes),
                remainingPercent: remaining(fromUsedPercent: secondary.usedPercent),
                resetAt: validResetDate(secondary.resetsAt),
                detail: nil
            ))
        }
        return SubscriptionQuotaGroup(
            id: "codex:subscription",
            source: .codex,
            title: "Codex",
            subtitle: normalizedText(limits.planType?.uppercased()),
            periods: periods,
            extraUsage: nil
        )
    }

    private static func kimiGroup(_ result: KimiQuotaResult) -> SubscriptionQuotaGroup {
        var periods: [SubscriptionQuotaPeriod] = []
        // 与 Kimi 官方/CC Switch 的阅读顺序一致：短窗口（通常 5 小时）在前，
        // 顶层 usage 对应的周额度在后。若后端把同一行同时放进两处，只展示一次。
        let visibleLimits = result.limits.filter { row in
            guard let summary = result.summary else { return true }
            return !sameKimiQuota(row, summary)
        }
        let sortedLimits = visibleLimits.enumerated().sorted { lhs, rhs in
            let left = kimiSortKey(lhs.element)
            let right = kimiSortKey(rhs.element)
            if left != right { return left < right }
            if lhs.element.name != rhs.element.name {
                return (lhs.element.name ?? "") < (rhs.element.name ?? "")
            }
            return lhs.offset < rhs.offset
        }
        var occurrences: [String: Int] = [:]
        for (_, row) in sortedLimits {
            let key = kimiPeriodKey(row)
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            periods.append(kimiPeriod(
                row,
                id: "kimi-code:subscription:limit:\(key):\(occurrence)",
                fallbackLabel: row.name ?? "额度"
            ))
        }
        if let summary = result.summary {
            periods.append(kimiPeriod(
                summary,
                id: "kimi-code:subscription:summary",
                fallbackLabel: "周额度"
            ))
        }

        let extra = result.extraUsage.map {
            SubscriptionQuotaExtraUsage(
                balanceCents: $0.balanceCents,
                totalCents: $0.totalCents,
                monthlyChargeLimitEnabled: $0.monthlyChargeLimitEnabled,
                monthlyChargeLimitCents: $0.monthlyChargeLimitCents,
                monthlyUsedCents: $0.monthlyUsedCents,
                currency: $0.currency
            )
        }
        return SubscriptionQuotaGroup(
            id: "kimi-code:subscription",
            source: .kimiCode,
            title: "Kimi Code",
            subtitle: result.origin == .officialAPI ? "KIMI API" : "LOCAL",
            periods: periods,
            extraUsage: extra
        )
    }

    private static func kimiPeriod(
        _ row: KimiQuotaRow,
        id: String,
        fallbackLabel: String
    ) -> SubscriptionQuotaPeriod {
        SubscriptionQuotaPeriod(
            id: id,
            label: row.window.map(label(kimiWindow:)) ?? fallbackLabel,
            remainingPercent: clampPercent(row.remainingPercent),
            resetAt: parseISO8601(row.resetAt),
            // Kimi 没有公开这组整数的稳定业务单位；只展示百分比与重置时间，
            // 避免被误解成 Token 数或请求数。
            detail: nil
        )
    }

    private static func arkGroups(_ snapshot: ArkPlanQuotaSnapshot?) -> [SubscriptionQuotaGroup] {
        guard let snapshot else { return [] }
        return snapshot.items
            .filter(\.subscribed)
            .sorted(by: arkItemOrder)
            .map { item in
                var occurrences: [String: Int] = [:]
                let periods = item.periods.sorted(by: arkPeriodOrder).map { period in
                    let occurrence = occurrences[period.label, default: 0]
                    occurrences[period.label] = occurrence + 1
                    return SubscriptionQuotaPeriod(
                        id: "ark:\(item.product):\(period.label):\(occurrence)",
                        label: label(arkPeriod: period.label),
                        remainingPercent: clampPercent(period.remainingPercent),
                        resetAt: parseISO8601(period.resetAt),
                        detail: arkDetail(period, product: item.product)
                    )
                }
                return SubscriptionQuotaGroup(
                    id: "ark:\(item.product)",
                    source: .ark,
                    title: arkTitle(item.product),
                    subtitle: normalizedText(item.tier?.uppercased()),
                    periods: periods,
                    extraUsage: nil
                )
            }
    }

    private static func arkDetail(_ period: ArkPlanQuotaPeriod, product: String) -> String? {
        guard let used = period.used, let total = period.total else { return nil }
        let base = "已用 \(quantity(used)) / \(quantity(total))"
        return product.hasPrefix("agent-plan") ? "\(base) AFP" : base
    }

    private static func arkTitle(_ product: String) -> String {
        switch product {
        case "agent-plan": return "火山方舟 Agent Plan"
        case "coding-plan": return "火山方舟 Coding Plan"
        case "agent-plan-team": return "火山方舟 Agent Plan 团队版"
        case "coding-plan-team": return "火山方舟 Coding Plan 团队版"
        default: return "火山方舟 \(product)"
        }
    }

    private static func label(arkPeriod: String) -> String {
        switch arkPeriod.lowercased() {
        case "5h": return "5小时"
        case "weekly": return "周"
        case "monthly": return "月"
        case "session": return "会话"
        default: return arkPeriod
        }
    }

    private static func label(windowMinutes: Int) -> String {
        switch windowMinutes {
        case 300: return "5小时"
        case 10_080: return "周"
        case 43_200: return "月"
        default:
            if windowMinutes > 0, windowMinutes % 1_440 == 0 {
                return "\(windowMinutes / 1_440)天"
            }
            if windowMinutes > 0, windowMinutes % 60 == 0 {
                return "\(windowMinutes / 60)小时"
            }
            return "\(windowMinutes)分钟"
        }
    }

    private static func label(kimiWindow: KimiQuotaWindow) -> String {
        switch (kimiWindow.duration, kimiWindow.unit) {
        case (5, .hour): return "5小时"
        case (1, .week): return "周"
        case (1, .day): return "日"
        case (let value, .minute): return "\(value)分钟"
        case (let value, .hour): return "\(value)小时"
        case (let value, .day): return "\(value)天"
        case (let value, .week): return "\(value)周"
        }
    }

    private static func remaining(fromUsedPercent usedPercent: Double) -> Double? {
        clampPercent(100 - usedPercent)
    }

    private static func clampPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    private static func validResetDate(_ value: Date) -> Date? {
        value.timeIntervalSince1970 > 0 ? value : nil
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISO8601DateFormatter.subscriptionFractional.date(from: value)
            ?? ISO8601DateFormatter.subscriptionStandard.date(from: value)
    }

    private static func arkItemOrder(_ lhs: ArkPlanQuotaItem, _ rhs: ArkPlanQuotaItem) -> Bool {
        let left = arkProductRank(lhs.product)
        let right = arkProductRank(rhs.product)
        return left == right ? lhs.product < rhs.product : left < right
    }

    private static func arkProductRank(_ product: String) -> Int {
        switch product {
        case "agent-plan": return 0
        case "coding-plan": return 1
        case "agent-plan-team": return 2
        case "coding-plan-team": return 3
        default: return 100
        }
    }

    private static func arkPeriodOrder(_ lhs: ArkPlanQuotaPeriod, _ rhs: ArkPlanQuotaPeriod) -> Bool {
        let left = arkPeriodRank(lhs.label)
        let right = arkPeriodRank(rhs.label)
        return left == right ? lhs.label < rhs.label : left < right
    }

    private static func arkPeriodRank(_ label: String) -> Int {
        switch label.lowercased() {
        case "5h", "session": return 0
        case "weekly": return 1
        case "monthly": return 2
        default: return 100
        }
    }

    private static func kimiSortKey(_ row: KimiQuotaRow) -> Int {
        guard let window = row.window else { return Int.max }
        let minutes: Int
        switch window.unit {
        case .minute: minutes = window.duration
        case .hour: minutes = safeMultiply(window.duration, 60)
        case .day: minutes = safeMultiply(window.duration, 1_440)
        case .week: minutes = safeMultiply(window.duration, 10_080)
        }
        return max(minutes, 0)
    }

    private static func safeMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let value = lhs.multipliedReportingOverflow(by: rhs)
        return value.overflow ? Int.max : value.partialValue
    }

    private static func sameKimiQuota(_ lhs: KimiQuotaRow, _ rhs: KimiQuotaRow) -> Bool {
        lhs.window == rhs.window
            && lhs.used == rhs.used
            && lhs.limit == rhs.limit
            && lhs.resetAt == rhs.resetAt
    }

    private static func kimiPeriodKey(_ row: KimiQuotaRow) -> String {
        guard let window = row.window else {
            return normalizedIDPart(row.name ?? "unknown")
        }
        return kimiWindowKey(window)
    }

    private static func kimiWindowKey(_ window: KimiQuotaWindow) -> String {
        "\(window.unit.rawValue)-\(window.duration)"
    }

    private static func normalizedIDPart(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let normalized = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return normalized.isEmpty ? "unknown" : normalized
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    private static func quantity(_ value: Double) -> String {
        if value.rounded() == value,
           value >= Double(Int64.min), value <= Double(Int64.max) {
            return String(Int64(value))
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

private extension ISO8601DateFormatter {
    static let subscriptionStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let subscriptionFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
