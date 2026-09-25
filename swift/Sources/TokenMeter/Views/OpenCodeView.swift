import SwiftUI
import Charts

// OpenCode 面板只展示本机 SQLite 中的结构化聚合字段，不读取或展示会话正文。
struct OpenCodeView: View {
    @EnvironmentObject var state: AppState
    @State private var weekHover: String?
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let result = state.opencode.result {
                    todayCard(result)
                    weekChartCard(result)
                    modelsCard(result)
                    privacyCard
                } else if state.opencode.loading {
                    SourceStateView(loading: true, message: "正在读取…")
                } else if let error = state.opencode.error {
                    SourceStateView(message: error)
                } else {
                    SourceStateView(message: "未找到 OpenCode 本地数据")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task { await state.loadOpenCode() }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "terminal.fill",
            title: "OpenCode Monitor",
            color: Theme.opencode,
            process: state.opencode.proc,
            refreshing: state.opencode.loading,
            onBack: onBack,
            onRefresh: { Task { await state.loadOpenCode(force: true) } },
            onSettings: onSettings
        )
    }

    private func todayCard(_ result: OpenCodeUsageResult) -> some View {
        let today = result.today
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日用量", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 0) {
                    SourceMetric(title: "Token", value: Fmt.tokensShort(today?.totalTokens ?? 0))
                    SourceMetric(title: "消息", value: Fmt.int(today?.messageCount ?? 0))
                    SourceMetric(title: "会话", value: Fmt.int(today?.sessionCount ?? 0))
                    SourceMetric(
                        title: "缓存命中",
                        value: today?.cacheHitRate.map { Fmt.percent($0) } ?? "—"
                    )
                }
                Divider()
                Text("近 7 天 \(Fmt.tokensShort(result.weekTotal)) tokens · \(Fmt.int(result.weekMessages)) 条 assistant 消息 · \(Fmt.int(result.weekSessions)) 个日会话")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func weekChartCard(_ result: OpenCodeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近 7 天 Token", systemImage: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                ChartHover.caption(hover: weekHover, buckets: result.days.map { day in
                    (
                        label: Fmt.mmdd(day.date),
                        total: day.cachedInputTokens + day.cacheWriteTokens
                            + day.inputTokens + day.outputTokens + day.reasoningTokens,
                        parts: [
                            ("缓存读取", day.cachedInputTokens, Theme.hit),
                            ("缓存写入", day.cacheWriteTokens, Theme.miss),
                            ("新输入", day.inputTokens, Theme.input),
                            ("输出", day.outputTokens + day.reasoningTokens, Theme.response),
                        ]
                    )
                })
                Chart {
                    ForEach(result.days) { day in
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("缓存读取", day.cachedInputTokens)
                        ).foregroundStyle(by: .value("类型", "缓存读取"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("缓存写入", day.cacheWriteTokens)
                        ).foregroundStyle(by: .value("类型", "缓存写入"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("新输入", day.inputTokens)
                        ).foregroundStyle(by: .value("类型", "新输入"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("输出", day.outputTokens + day.reasoningTokens)
                        ).foregroundStyle(by: .value("类型", "输出"))
                    }
                    HoverDateRule(date: weekHover)
                }
                .chartXSelection(value: $weekHover)
                .chartForegroundStyleScale([
                    "缓存读取": Theme.hit,
                    "缓存写入": Theme.miss,
                    "新输入": Theme.input,
                    "输出": Theme.response,
                ])
                .chartLegend(position: .bottom, spacing: 4)
                .tokenYAxis()
                .frame(height: 150)
            }
        }
    }

    private func modelsCard(_ result: OpenCodeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("模型分布（近 7 天）", systemImage: "cpu")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if result.weekCost > 0 {
                        Text("原生估算 \(Fmt.usd(result.weekCost))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if result.models.isEmpty {
                    Text("暂无数据").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    let maximum = max(result.models.first?.totalTokens ?? 0, 1)
                    ForEach(result.models.prefix(6)) { model in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(model.model)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(Fmt.tokensShort(model.totalTokens)) · \(Fmt.int(model.messageCount)) 条")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            QuotaBar(progress: Double(model.totalTokens) / Double(maximum), tint: Theme.opencode)
                        }
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        SourcePrivacyCard(text: "仅从本机 SQLite 白名单读取模型、时间、Token 与费用字段；不读取或上报提示词、回复、代码和凭据。")
    }
}
