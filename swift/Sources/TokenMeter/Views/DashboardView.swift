import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState
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
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text("TokenMeter")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            iconButton("globe") { PlatformPortal.shared.open() }
                .help("打开 DeepSeek 开放平台")
            iconButton("arrow.clockwise") { state.refreshAll() }
            iconButton("gearshape") { onSettings() }
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
