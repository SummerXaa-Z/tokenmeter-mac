import SwiftUI
import Charts

// Kimi Code 面板只展示本机 wire.jsonl 中 usage.record 的结构化用量字段。
// 不读取对话正文、工具参数或凭据，也不产生任何网络上报。
struct KimiView: View {
    @EnvironmentObject var state: AppState
    @State private var weekHover: String?
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let result = state.kimi.result {
                    todayCard(result)
                    hoursCard(result)
                    weekChartCard(result)
                    modelsCard(result)
                    privacyCard
                } else if state.kimi.loading {
                    SourceStateView(loading: true, message: "正在读取…")
                } else if let error = state.kimi.error {
                    SourceStateView(message: error)
                } else {
                    SourceStateView(message: "未找到 Kimi Code 本地数据")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task { await state.loadKimi() }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "moon.stars.fill",
            title: "Kimi Code Monitor",
            color: Theme.kimi,
            process: state.kimi.proc,
            refreshing: state.kimi.loading,
            onBack: onBack,
            onRefresh: { Task { await state.loadKimi(force: true) } },
            onSettings: onSettings
        )
    }

    private func todayCard(_ result: KimiUsageResult) -> some View {
        let today = result.today
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日用量", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 0) {
                    SourceMetric(title: "Token", value: Fmt.tokensShort(today?.totalTokens ?? 0))
                    SourceMetric(title: "请求", value: Fmt.int(today?.messageCount ?? 0))
                    SourceMetric(title: "会话", value: Fmt.int(today?.sessionCount ?? 0))
                    SourceMetric(
                        title: "缓存命中",
                        value: today?.cacheHitRate.map { Fmt.percent($0) } ?? "—"
                    )
                }

                Divider()

                HStack(spacing: 0) {
                    SourceMetric(title: "新输入", value: Fmt.tokensShort(today?.inputTokens ?? 0))
                    SourceMetric(title: "缓存读取", value: Fmt.tokensShort(today?.cachedInputTokens ?? 0))
                    SourceMetric(title: "缓存写入", value: Fmt.tokensShort(today?.cacheCreationTokens ?? 0))
                    SourceMetric(title: "输出", value: Fmt.tokensShort(today?.outputTokens ?? 0))
                }

                Divider()

                Text("近 7 天 \(Fmt.tokensShort(result.weekTotal)) tokens · \(Fmt.int(result.weekMessages)) 次请求 · \(Fmt.int(result.weekSessions)) 个会话")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hoursCard(_ result: KimiUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日分时（Token）", systemImage: "clock")
                    .font(.system(size: 12, weight: .semibold))
                SourceHourChart(
                    bars: result.todayHours.map { .init(hour: $0.hour, tokens: $0.totalTokens) },
                    color: Theme.kimi
                )
            }
        }
    }

    private func weekChartCard(_ result: KimiUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近 7 天 Token", systemImage: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                ChartHover.caption(hover: weekHover, buckets: result.days.map { day in
                    (
                        label: Fmt.mmdd(day.date),
                        total: day.cachedInputTokens + day.cacheCreationTokens
                            + day.inputTokens + day.outputTokens,
                        parts: [
                            ("缓存读取", day.cachedInputTokens, Theme.hit),
                            ("缓存写入", day.cacheCreationTokens, Theme.miss),
                            ("新输入", day.inputTokens, Theme.input),
                            ("输出", day.outputTokens, Theme.response),
                        ]
                    )
                })
                Chart {
                    ForEach(result.days) { day in
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("缓存读取", day.cachedInputTokens)
                        )
                        .foregroundStyle(by: .value("类型", "缓存读取"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("缓存写入", day.cacheCreationTokens)
                        )
                        .foregroundStyle(by: .value("类型", "缓存写入"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("新输入", day.inputTokens)
                        )
                        .foregroundStyle(by: .value("类型", "新输入"))
                        BarMark(
                            x: .value("日期", Fmt.mmdd(day.date)),
                            y: .value("输出", day.outputTokens)
                        )
                        .foregroundStyle(by: .value("类型", "输出"))
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

    private func modelsCard(_ result: KimiUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("模型分布（近 7 天）", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                if result.models.isEmpty {
                    Text("暂无数据")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    let maximum = max(result.models.first?.totalTokens ?? 0, 1)
                    ForEach(result.models.prefix(6)) { model in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(model.model)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(Fmt.tokensShort(model.totalTokens)) · \(Fmt.int(model.messageCount)) 次请求")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            QuotaBar(progress: Double(model.totalTokens) / Double(maximum), tint: Theme.kimi)
                        }
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        SourcePrivacyCard(
            text: "仅只读解析本机 Kimi Code session 中的 usage.record（时间、模型与 Token）；不读取对话正文、工具参数或凭据，也不会上传任何原始内容或统计结果。"
        )
    }
}
