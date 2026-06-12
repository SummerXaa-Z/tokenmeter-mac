import SwiftUI
import Charts

// Codex 用量面板：配额双窗口（5 小时 / 周）+ 今日用量 + 7 天柱图。
// 数据全部来自本地 ~/.codex/sessions，刷新即重扫。
struct CodexView: View {
    @State private var result: CodexUsageResult?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let r = result {
                    rateLimitCard(r.rateLimits)
                    todayCard(r)
                    weekChartCard(r)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    Text("未找到 Codex 本地数据（~/.codex/sessions）")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .task { await reload() }
    }

    func reload() async {
        loading = true
        let r = await Task.detached(priority: .userInitiated) { CodexUsage.load() }.value
        result = r
        loading = false
    }

    // MARK: - 配额窗口
    private func rateLimitCard(_ limits: CodexRateLimits?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("订阅配额", systemImage: "speedometer")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let plan = limits?.planType {
                        Text(plan.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.codex.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.codex)
                    }
                }
                if let limits {
                    if let p = limits.primary {
                        gaugeRow("5 小时窗口", p)
                    }
                    if let s = limits.secondary {
                        gaugeRow("周窗口", s)
                    }
                    Text("数据截至 \(Self.relative(limits.asOf))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("暂无配额数据（最近 7 天没有 Codex 会话）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // 与官方面板口径一致：展示「剩余」百分比，进度条表示剩余量
    private func gaugeRow(_ title: String, _ w: CodexRateWindow) -> some View {
        let remaining = max(100 - w.usedPercent, 0)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text("剩余 \(Int(remaining))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.remainingColor(remaining))
                Text("· \(Self.resetText(w.resetsAt)) 重置")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ProgressView(value: min(remaining, 100), total: 100)
                .tint(Self.remainingColor(remaining))
        }
    }

    // MARK: - 今日
    private func todayCard(_ r: CodexUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日用量", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                let t = r.today
                HStack(spacing: 0) {
                    stat("Token", Fmt.tokensShort(t?.totalTokens ?? 0))
                    stat("会话", "\(t?.sessionCount ?? 0)")
                    stat("缓存命中", t?.cacheHitRate.map { String(format: "%.0f%%", $0) } ?? "—")
                    stat("输出", Fmt.tokensShort((t?.outputTokens ?? 0)))
                }
                Divider()
                HStack {
                    Text("近 7 天合计 \(Fmt.tokensShort(r.weekTotal)) tokens · \(r.weekSessions) 个会话")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 7 天柱图
    private func weekChartCard(_ r: CodexUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近 7 天 Token", systemImage: "chart.bar")
                    .font(.system(size: 12, weight: .semibold))
                Chart(r.days) { day in
                    BarMark(
                        x: .value("日期", Fmt.mmdd(day.date)),
                        y: .value("缓存", day.cachedInputTokens))
                    .foregroundStyle(by: .value("类型", "缓存输入"))
                    BarMark(
                        x: .value("日期", Fmt.mmdd(day.date)),
                        y: .value("非缓存", max(day.inputTokens - day.cachedInputTokens, 0)))
                    .foregroundStyle(by: .value("类型", "新输入"))
                    BarMark(
                        x: .value("日期", Fmt.mmdd(day.date)),
                        y: .value("输出", day.outputTokens))
                    .foregroundStyle(by: .value("类型", "输出"))
                }
                .chartForegroundStyleScale([
                    "缓存输入": Theme.hit, "新输入": Theme.miss, "输出": Theme.response,
                ])
                .chartLegend(position: .bottom, spacing: 4)
                .frame(height: 150)
            }
        }
    }

    // MARK: - helpers
    private static func remainingColor(_ remaining: Double) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 30 { return .orange }
        return Theme.codex
    }

    private static func resetText(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "已" }
        let hours = Int(interval) / 3600
        if hours >= 24 { return "\(hours / 24) 天后" }
        if hours >= 1 { return "\(hours) 小时后" }
        return "\(max(Int(interval) / 60, 1)) 分钟后"
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: date, relativeTo: Date())
    }
}
