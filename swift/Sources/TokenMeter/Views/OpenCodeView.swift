import SwiftUI
import Charts

// OpenCode 面板只展示本机 SQLite 中的结构化聚合字段，不读取或展示会话正文。
struct OpenCodeView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                SourceCollectionContent(cache: state.opencode, emptyMessage: "未找到 OpenCode 本地数据") { result in
                    todayCard(result)
                    weekChartCard(result)
                    modelsCard(result)
                    privacyCard
                }
                SourceAPICostCard(source: .opencode, liveDayModels: state.opencode.result?.dayModels)
                SourceWeekCompareCard(source: .opencode)
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
        SourceTrendCard(
            source: .opencode,
            weekDays: result.days.map { day in
                .init(date: day.date, parts: [
                    ("缓存读取", day.cachedInputTokens, Theme.hit),
                    ("缓存写入", day.cacheWriteTokens, Theme.miss),
                    ("新输入", day.inputTokens, Theme.input),
                    ("输出", day.outputTokens + day.reasoningTokens, Theme.response),
                ])
            },
            liveDayModels: result.dayModels)
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
