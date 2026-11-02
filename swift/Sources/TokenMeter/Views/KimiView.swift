import SwiftUI
import Charts

// Kimi Code 面板只展示本机 wire.jsonl 中 usage.record 的结构化用量字段。
// 不读取对话正文、工具参数或凭据，也不产生任何网络上报。
struct KimiView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.usageNow) private var now
    @Environment(\.sourceUsageRange) private var usageRange
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                ScopedSourceUsageCard(source: .kimi)
                SourceCollectionContent(cache: state.kimi, emptyMessage: "未找到 Kimi Code 本地数据") { result in
                    if usageRange == nil { todayCard(result) }
                    if usageRange != .day { hoursCard(result) }
                    weekChartCard(result)
                    if usageRange == nil { modelsCard(result) }
                    privacyCard
                }
                SourceAPICostCard(source: .kimi, liveDayModels: state.kimi.result?.dayModels)
                SourceWeekCompareCard(source: .kimi)
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
        let today = result.day(on: DateUtil.key(now))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日用量", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 0) {
                    SourceMetric(title: "Token", value: (today?.totalTokens).map(Fmt.tokensShort) ?? "—")
                    SourceMetric(title: "请求", value: (today?.messageCount).map(Fmt.int) ?? "—")
                    SourceMetric(title: "会话", value: (today?.sessionCount).map(Fmt.int) ?? "—")
                    SourceMetric(
                        title: "缓存命中",
                        value: today?.cacheHitRate.map { Fmt.percent($0) } ?? "—"
                    )
                }

                Divider()

                HStack(spacing: 0) {
                    SourceMetric(title: "新输入", value: (today?.inputTokens).map(Fmt.tokensShort) ?? "—")
                    SourceMetric(title: "缓存读取", value: (today?.cachedInputTokens).map(Fmt.tokensShort) ?? "—")
                    SourceMetric(title: "缓存写入", value: (today?.cacheCreationTokens).map(Fmt.tokensShort) ?? "—")
                    SourceMetric(title: "输出", value: (today?.outputTokens).map(Fmt.tokensShort) ?? "—")
                }

                Divider()

                Text("近 7 天 \(Fmt.tokensShort(result.weekTotal)) tokens · \(Fmt.int(result.weekMessages)) 次请求 · \(Fmt.int(result.weekSessions)) 个会话")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hoursCard(_ result: KimiUsageResult) -> some View {
        SourceHourCard(
            source: .kimi,
            bars: (result.hourlyTokens(on: DateUtil.key(now)) ?? [:]).sorted { $0.key < $1.key }.map { .init(hour: $0.key, tokens: $0.value) },
            observedDate: result.days.last?.date,
            color: Theme.kimi
        )
    }

    private func weekChartCard(_ result: KimiUsageResult) -> some View {
        SourceTrendCard(
            source: .kimi,
            weekDays: result.days.map { day in
                .init(date: day.date, parts: [
                    ("缓存读取", day.cachedInputTokens, Theme.hit),
                    ("缓存写入", day.cacheCreationTokens, Theme.miss),
                    ("新输入", day.inputTokens, Theme.input),
                    ("输出", day.outputTokens, Theme.response),
                ])
            },
            liveDayModels: result.dayModels, initialRange: usageRange)
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
