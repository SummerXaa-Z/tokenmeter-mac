import SwiftUI
import Charts

// Codex 用量面板：配额双窗口（5 小时 / 周）+ 今日用量 + 7 天柱图。
// 用量来自本地 ~/.codex/sessions；官方实时配额由独立开关控制。
struct CodexView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.usageNow) private var now
    @Environment(\.sourceUsageRange) private var usageRange
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                ScopedSourceUsageCard(source: .codex)
                if let error = state.codex.error {
                    SourceReadFailureCard(message: error, showingLastGood: state.codex.result != nil)
                }
                if !state.codexAllRateLimits.isEmpty {
                    ForEach(state.codexAllRateLimits, id: \.limitId) { rateLimitCard($0) }
                } else if state.codex.result != nil || state.codexLiveQuotaEnabled {
                    rateLimitCard(nil)
                }
                if let r = state.codex.result {
                    if usageRange == nil { todayCard(r) }
                    if usageRange != .day { hoursCard(r) }
                    weekChartCard(r)
                    if usageRange == nil { modelCard(r) }
                    projectCard(r)
                } else if state.codex.loading {
                    SourceStateView(loading: true, message: "正在读取…")
                } else if state.codex.error == nil {
                    SourceStateView(message: "未找到 Codex 本地数据（~/.codex/sessions）")
                }
                SourceAPICostCard(source: .codex, liveDayModels: state.codex.result?.dayModels)
                SourceWeekCompareCard(source: .codex)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        // 命中缓存则秒回，过期才重扫
        .task { await state.loadCodex() }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "terminal",
            title: "Codex Monitor",
            color: Theme.codex,
            process: state.codex.proc,
            refreshing: state.codex.loading,
            onBack: onBack,
            onRefresh: { Task { await state.loadCodex(force: true) } },
            onSettings: onSettings
        )
    }

    // MARK: - 配额窗口
    // 消费注入的 usageNow（真实 app 由 RootView 的 30 秒 Timeline 驱动重渲，
    // 离屏渲染为固定渲染钟）——自带 TimelineView 会在渲染夹具里引入活钟，
    // 配额新鲜度随真实渲染时刻翻转。
    private func rateLimitCard(_ limits: CodexRateLimits?) -> some View {
        rateLimitContent(limits, now: now)
    }

    private func rateLimitContent(_ limits: CodexRateLimits?, now: Date) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // 主通道是订阅配额；灰度/实验通道(如 Spark)单独成卡,用官方名
                    Label(limits?.isMain == false ? (limits?.limitName ?? limits?.limitId ?? "其他配额")
                                                  : "订阅配额",
                          systemImage: limits?.isMain == false ? "testtube.2" : "speedometer")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let plan = limits?.planType {
                        Text(plan.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.codex.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.codex)
                    }
                }
                if let limits {
                    if let p = limits.primary {
                        gaugeRow(Self.windowTitle(p.windowMinutes), p, now: now)
                    }
                    if let s = limits.secondary {
                        gaugeRow(Self.windowTitle(s.windowMinutes), s, now: now)
                    }
                    Text("数据截至 \(Self.relative(limits.asOf, now: now))")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                        .help(state.codexLiveQuotaEnabled
                            ? "优先显示官方实时配额；查询失败时使用本地快照"
                            : "实时查询已关闭；快照来自最近一次 Codex 请求")
                } else {
                    Text(state.codexLiveQuotaEnabled
                        ? "暂无可验证的配额数据，请检查 Codex 登录状态或稍后刷新"
                        : "暂无本地配额快照，可在设置中主动开启官方实时查询")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // 与官方面板口径一致：展示「剩余」百分比，进度条表示剩余量
    private func gaugeRow(_ title: String, _ w: CodexRateWindow, now: Date) -> some View {
        let remaining = QuotaWindowFreshness.remainingPercent(w, now: now)
        let expired = QuotaWindowFreshness.isExpired(resetAt: w.resetsAt, now: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(remaining.map { "剩余 \(Int($0))%" } ?? "剩余未知")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(remaining.map(Self.remainingColor) ?? .secondary)
                if !expired, w.resetsAt.timeIntervalSince1970 > 0 {
                    Text("· \(QuotaPace.countdown(from: now, to: w.resetsAt))重置")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
            }
            let pace = QuotaPace.compute(
                remainingPercent: remaining,
                windowStart: QuotaPace.windowStart(
                    resetAt: w.resetsAt.timeIntervalSince1970 > 0 ? w.resetsAt : nil,
                    seconds: TimeInterval(w.windowMinutes) * 60),
                resetAt: w.resetsAt, now: now)
            if let remaining {
                QuotaBar(
                    progress: remaining / 100,
                    tint: Self.remainingColor(remaining),
                    marker: pace?.evenPaceRemaining)
            } else {
                Text(expired ? "窗口已结束，请刷新配额快照" : "缺少可验证的窗口数据，请刷新")
                    .font(Theme.footnoteFont).foregroundStyle(.secondary)
            }
            if let pace {
                if pace.isAhead {
                    QuotaPaceLine(pace: pace, text: pace.summary(now: now))
                } else {
                    Text(pace.summary(now: now))
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 今日
    private func todayCard(_ r: CodexUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日用量", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                let t = r.day(on: DateUtil.key(now))
                HStack(spacing: 0) {
                    SourceMetric(title: "Token", value: (t?.totalTokens).map(Fmt.tokensShort) ?? "—")
                    SourceMetric(title: "会话", value: (t?.sessionCount).map(Fmt.int) ?? "—")
                    SourceMetric(
                        title: "缓存命中",
                        value: t?.cacheHitRate.map { Fmt.percent($0) } ?? "—"
                    )
                    SourceMetric(title: "输出", value: (t?.outputTokens).map(Fmt.tokensShort) ?? "—")
                }
                Divider()
                HStack {
                    Text("近 7 天合计 \(Fmt.tokensShort(r.weekTotal)) tokens · \(Fmt.int(r.weekSessions)) 个会话")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 7|30 天柱图
    private func weekChartCard(_ r: CodexUsageResult) -> some View {
        SourceTrendCard(
            source: .codex,
            weekDays: r.days.map { day in
                .init(date: day.date, parts: [
                    ("缓存输入", day.cachedInputTokens, Theme.hit),
                    ("新输入", max(day.inputTokens - day.cachedInputTokens, 0), Theme.input),
                    ("输出", day.outputTokens, Theme.response),
                ])
            },
            liveDayModels: r.dayModels, initialRange: usageRange)
    }

    // MARK: - 今日分时
    private func hoursCard(_ r: CodexUsageResult) -> some View {
        SourceHourCard(
            source: .codex,
            bars: (r.hourlyTokens(on: DateUtil.key(now)) ?? [:]).sorted { $0.key < $1.key }.map { .init(hour: $0.key, tokens: $0.value) },
            observedDate: r.days.last?.date,
            color: Theme.codex
        )
    }

    // MARK: - 模型分布
    private func modelCard(_ r: CodexUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("模型分布（近 7 天）", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                if r.models.isEmpty {
                    Text("暂无数据").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    let maxTotal = max(r.models.first?.totalTokens ?? 0, 1)
                    ForEach(r.models.prefix(5)) { m in
                        barRow(m.model, m.totalTokens, maxTotal, suffix: "")
                    }
                }
            }
        }
    }

    // MARK: - 项目分布
    private func projectCard(_ r: CodexUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("项目分布（近 7 天）", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
                if r.projects.isEmpty {
                    Text("暂无数据").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    let maxTotal = max(r.projects.first?.totalTokens ?? 0, 1)
                    ForEach(r.projects.prefix(6)) { pj in
                        barRow(pj.project, pj.totalTokens, maxTotal,
                               suffix: " · \(pj.sessionCount) 会话")
                    }
                }
            }
        }
    }

    private func barRow(_ name: String, _ total: Int, _ maxTotal: Int, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Fmt.tokensShort(total))\(suffix)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            QuotaBar(progress: Double(total) / Double(maxTotal), tint: Theme.codex)
        }
    }

    // MARK: - helpers
    // 窗口标签从 window_minutes 推导，订阅计划/官方调整窗口时长时自动跟随
    private static func windowTitle(_ minutes: Int) -> String {
        if minutes % 10080 == 0 {
            let w = minutes / 10080
            return w == 1 ? "周窗口" : "\(w) 周窗口"
        }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天窗口" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时窗口" }
        return "\(minutes) 分钟窗口"
    }

    private static func remainingColor(_ remaining: Double) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 30 { return .orange }
        return Theme.codex
    }

    private static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: date, relativeTo: now)
    }
}
