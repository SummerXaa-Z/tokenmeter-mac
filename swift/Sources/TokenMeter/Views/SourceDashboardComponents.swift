import SwiftUI
import Charts

// 各来源页共用的轻量展示原语。只统一稳定的视觉结构，不试图把不同工具的
// Token、会话与配额语义塞进一个万能 Dashboard。
struct SourceDashboardHeader: View {
    let icon: String
    let title: String
    let color: Color
    var process: ProcessStatus.Snapshot?
    var showProcessCount = true
    var refreshing = false
    var onBack: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    // DashboardView 的地球入口；其他来源页不传
    var onOpenPlatform: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                SourceDashboardIconButton(name: "chevron.left", help: "返回上一页", action: onBack)
            }
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(title).font(Theme.pageTitleFont)
            if let process {
                RunningBadge(snapshot: process, showCount: showProcessCount)
            }
            Spacer()
            if let onOpenPlatform {
                SourceDashboardIconButton(
                    name: "globe", help: "打开 DeepSeek 开放平台", action: onOpenPlatform)
            }
            if let onRefresh {
                SourceDashboardIconButton(
                    name: "arrow.clockwise", help: "刷新数据",
                    refreshing: refreshing, action: onRefresh)
            }
            if let onSettings {
                SourceDashboardIconButton(name: "gearshape", help: "打开设置", action: onSettings)
            }
        }
    }
}

// 图标按钮统一原语：28×28 热区、悬停加深、可选 tooltip 与刷新中状态。
// 全 app 的裸图标按钮都应走这里，不再各自手写 Button + .plain。
struct SourceDashboardIconButton: View {
    let name: String
    var help: String? = nil
    var refreshing = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(hovering ? Color.primary : Color.secondary)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(OptionalHelp(text: help))
        .accessibilityLabel(help ?? "")
    }
}

// .help() 不接受 String?，用 modifier 包一层条件
private struct OptionalHelp: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

// 各来源页统一的加载/空/错误占位：加载态带文案，错误与空态共用一套排版。
// 不再出现裸 spinner、无兜底 else、水平边距不一致的各写一套。
struct SourceStateView: View {
    var loading = false
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Text(loading ? "正在读取…" : message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 20)
    }
}

// 今日分时柱图：24 小时单序列、空小时变暗，四个本地来源页共用，
// 保证高度、刻度与空柱处理一致（此前 70/76/125 三种高度、三种 X 轴写法）。
struct SourceHourChart: View {
    struct Bar: Identifiable {
        let hour: Int
        let tokens: Int
        var id: Int { hour }
    }
    let bars: [Bar]
    let color: Color

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("小时", bar.hour),
                y: .value("Token", bar.tokens)
            )
            .foregroundStyle(color.opacity(bar.tokens > 0 ? 0.9 : 0.2))
        }
        .chartXScale(domain: 0...23)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) { Text("\(hour)时") }
                }
            }
        }
        .tokenYAxis()
        .frame(height: 100)
    }
}

struct SourceMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SourcePrivacyCard: View {
    let text: String

    var body: some View {
        Card {
            Label(text, systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
