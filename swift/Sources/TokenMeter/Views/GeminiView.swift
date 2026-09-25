import SwiftUI
import Charts

struct GeminiView: View {
    @EnvironmentObject var state: AppState
    @State private var weekHover: String?
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let result = state.gemini.result {
                    todayCard(result)
                    weekChartCard(result)
                    modelsCard(result)
                    privacyCard
                } else if state.gemini.loading {
                    SourceStateView(loading: true, message: "正在读取…")
                } else if let error = state.gemini.error {
                    SourceStateView(message: error)
                } else {
                    SourceStateView(message: "未找到 Gemini CLI 本地数据")
                }
                SourceWeekCompareCard(source: .gemini)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task { await state.loadGemini() }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "sparkle.magnifyingglass",
            title: "Gemini CLI Monitor",
            color: Theme.gemini,
            process: state.gemini.proc,
            refreshing: state.gemini.loading,
            onBack: onBack,
            onRefresh: { Task { await state.loadGemini(force: true) } },
            onSettings: onSettings
        )
    }

    private func todayCard(_ result: GeminiUsageResult) -> some View {
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
                Text("近 7 天 \(Fmt.tokensShort(result.weekTotal)) tokens · \(Fmt.int(result.weekMessages)) 条 Gemini 消息 · \(Fmt.int(result.weekSessions)) 个日会话")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func weekChartCard(_ result: GeminiUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近 7 天 Token", systemImage: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                ChartHover.caption(hover: weekHover, buckets: result.days.map { day in
                    (
                        label: Fmt.mmdd(day.date),
                        total: day.cachedInputTokens + day.inputTokens
                            + day.outputTokens + day.reasoningTokens,
                        parts: [
                            ("缓存读取", day.cachedInputTokens, Theme.hit),
                            ("新输入", day.inputTokens, Theme.input),
                            ("输出", day.outputTokens, Theme.response),
                            ("推理", day.reasoningTokens, Theme.miss),
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
                            y: .value("新输入", day.inputTokens)
                        ).foregroundStyle(by: .value("类型", "新输入"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("输出", day.outputTokens)
                        ).foregroundStyle(by: .value("类型", "输出"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("推理", day.reasoningTokens)
                        ).foregroundStyle(by: .value("类型", "推理"))
                    }
                    HoverDateRule(date: weekHover)
                }
                .chartXSelection(value: $weekHover)
                .chartForegroundStyleScale([
                    "缓存读取": Theme.hit,
                    "新输入": Theme.input,
                    "输出": Theme.response,
                    "推理": Theme.miss,
                ])
                .chartLegend(position: .bottom, spacing: 4)
                .tokenYAxis()
                .frame(height: 150)
            }
        }
    }

    private func modelsCard(_ result: GeminiUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("模型分布（近 7 天）", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
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
                            QuotaBar(progress: Double(model.totalTokens) / Double(maximum), tint: Theme.gemini)
                        }
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        SourcePrivacyCard(text: "仅解码 session 中的消息 ID、模型、时间和 Token 字段；对话、工具参数、代码与思考内容不会进入统计结果。")
    }
}
