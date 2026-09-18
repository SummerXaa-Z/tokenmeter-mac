import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void
    var onSettings: () -> Void
    var onDetail: (String) -> Void

    private var flash: UsageModelSummary? { state.usage?.model("flash") }
    private var pro: UsageModelSummary? { state.usage?.model("pro") }
    private var maxTokens: Int {
        max(flash?.totalTokens ?? 0, pro?.totalTokens ?? 0, 1)
    }
    private var today: UsageDay? {
        state.usage?.days.first { $0.date == DateUtil.today() }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            BalanceCard(balance: state.balance, state: state.balanceState,
                        todayCost: state.usageState == .ok ? today?.totalCost : nil,
                        monthCost: state.usageState == .ok ? state.usage?.monthCost : nil)
            UsageRow(modelKey: "flash", data: flash, maxTokens: maxTokens,
                     state: state.usageState, onTap: { onDetail("flash") })
            UsageRow(modelKey: "pro", data: pro, maxTokens: maxTokens,
                     state: state.usageState, onTap: { onDetail("pro") })
            UsageChartCard(usage: state.usage, state: state.usageState)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "gauge.with.dots.needle.50percent",
            title: "TokenMeter",
            color: Theme.brand,
            refreshing: state.balanceState == .loading || state.usageState == .loading,
            onBack: onBack,
            onRefresh: { state.refreshAll(force: true) },
            onSettings: onSettings,
            onOpenPlatform: { PlatformPortal.shared.open() }
        )
    }
}
