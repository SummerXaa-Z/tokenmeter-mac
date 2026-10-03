import SwiftUI

extension Provider {
    var historySource: HistorySource? {
        SourceCatalog.source(for: self)
    }

    // 平台账户与配置工具不是 Coding Agent 用量源。
    var codingHistorySource: HistorySource? {
        historySource.flatMap { $0.isCodingAgent ? $0 : nil }
    }

    var overviewIcon: String {
        switch self {
        case .deepseek: return "gauge.with.dots.needle.50percent"
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .kimi: return "moon.stars"
        case .opencode: return "terminal.fill"
        case .gemini: return "sparkle.magnifyingglass"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .qwen: return "q.circle"
        case .cursor: return "cursorarrow.rays"
        }
    }

    var overviewColor: Color {
        historySource?.overviewColor ?? Theme.brand
    }
}

struct OverviewProfileCard: View {
    let profile: PersonalUsageProfile
    let range: UsageHistoryRange

    var body: some View {
        OverviewSection {
            VStack(alignment: .leading, spacing: 9) {
                Label("个人 AI 画像", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 0) {
                    stat(activeDaysText, "活跃天数")
                    stat("\(profile.currentStreak)天", "当前连续")
                    stat(
                        profile.primarySource?.overviewName ?? "—",
                        profile.primaryShare.map { "主力 \(Int(($0 * 100).rounded()))%" }
                            ?? "主力工具"
                    )
                    stat("\(Fmt.int(profile.rangeSessions))", "\(range.scopeTitle)会话")
                }

                if !profile.badges.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(profile.badges, id: \.self) { badge in
                            // 画像标签是说明性徽章，与“不计入 Coding 合计”同款中性灰，
                            // 不占用品牌蓝的注意力预算
                            Text(badge)
                                .font(Theme.badgeFont.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }

                Divider()
                if let rate = profile.cacheHitRate {
                    HStack {
                        Text("\(range.scopeTitle)输入缓存复用")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((rate * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.hit)
                    }
                    QuotaBar(progress: rate, tint: Theme.hit)
                    Text("缓存读取 \(Fmt.tokensShort(profile.cachedInputTokens)) · 非缓存输入 \(Fmt.tokensShort(profile.nonCachedInputTokens)) · 按模型明细统计，不含 Cursor")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("\(range.scopeTitle)暂无输入缓存明细；刷新本地来源后生成，数据只保存在本机。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeDaysText: String {
        guard let days = range.fixedDayCount else { return "\(profile.activeDays)天" }
        return "\(profile.activeDays)/\(days)"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
