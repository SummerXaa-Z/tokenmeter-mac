import SwiftUI

// 各来源页共用的轻量展示原语。只统一稳定的视觉结构，不试图把不同工具的
// Token、会话与配额语义塞进一个万能 Dashboard。
struct SourceDashboardHeader: View {
    let icon: String
    let title: String
    let color: Color
    let process: ProcessStatus.Snapshot
    var showProcessCount = true
    var onBack: (() -> Void)?
    let onRefresh: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                SourceDashboardIconButton(name: "chevron.left", action: onBack)
            }
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(title).font(.system(size: 15, weight: .bold))
            RunningBadge(snapshot: process, showCount: showProcessCount)
            Spacer()
            SourceDashboardIconButton(name: "arrow.clockwise", action: onRefresh)
            SourceDashboardIconButton(name: "gearshape", action: onSettings)
        }
    }
}

struct SourceDashboardIconButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
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

struct SourceMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SourcePrivacyCard: View {
    let text: String

    var body: some View {
        Card {
            Label(text, systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
