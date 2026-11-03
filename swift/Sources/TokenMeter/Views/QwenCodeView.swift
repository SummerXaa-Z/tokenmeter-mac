import Charts
import SwiftUI

// Qwen Code 只读取官方本地聚合文件，不打开 chats 对话记录。
struct QwenCodeView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.usageNow) private var now
    @Environment(\.sourceUsageRange) private var usageRange
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                ScopedSourceUsageCard(source: .qwen)
                SourceCollectionContent(cache: state.qwen, emptyMessage: "未找到 Qwen Code 本地数据") { result in
                    if usageRange == nil { todayCard(result) }
                    if usageRange != .day { hourlyCard(result) }
                    weekCard(result)
                    if usageRange == nil { modelsCard(result) }
                    privacyCard
                }
                SourceAPICostCard(source: .qwen, liveDayModels: state.qwen.result?.dayModels)
                SourceWeekCompareCard(source: .qwen)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task { await state.loadQwen() }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "q.circle",
            title: "Qwen Code Monitor",
            color: Theme.qwen,
            process: state.qwen.proc,
            refreshing: state.qwen.loading,
            onBack: onBack,
            onRefresh: { Task { await state.loadQwen(force: true) } },
            onSettings: onSettings
        )
    }

    private func todayCard(_ result: QwenCodeUsageResult) -> some View {
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
                HStack(spacing: 10) {
                    // 分量配色与来源页趋势卡同一约定(新输入=input、缓存读取=hit、
                    // 输出=response、推理=miss)；今日未确认时显示 —，不冒充 0
                    tokenPart("新输入", today?.inputTokens, Theme.input)
                    tokenPart("缓存读取", today?.cachedInputTokens, Theme.hit)
                    tokenPart("输出", today?.outputTokens, Theme.response)
                    tokenPart("推理", today?.reasoningTokens, Theme.miss)
                }
            }
        }
    }

    private func tokenPart(_ title: String, _ value: Int?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(color)
            Text(value.map(Fmt.tokensShort) ?? "—")
                .font(.system(size: 11, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hourlyCard(_ result: QwenCodeUsageResult) -> some View {
        SourceHourCard(
            source: .qwen,
            bars: (result.hourlyTokens(on: DateUtil.key(now)) ?? [:]).sorted { $0.key < $1.key }.map { .init(hour: $0.key, tokens: $0.value) },
            observedDate: result.days.last?.date,
            color: Theme.qwen,
            note: "Qwen 在 Session 结束时写入聚合记录，因此小时归属按 Session 结束时间。"
        )
    }

    private func weekCard(_ result: QwenCodeUsageResult) -> some View {
        SourceTrendCard(
            source: .qwen,
            weekDays: result.days.map { day in
                .init(date: day.date, parts: [
                    ("缓存读取", day.cachedInputTokens, Theme.hit),
                    ("新输入", day.inputTokens, Theme.input),
                    ("输出", day.outputTokens, Theme.response),
                    ("推理", day.reasoningTokens, Theme.miss),
                ])
            },
            liveDayModels: result.dayModels, initialRange: usageRange)
    }

    private func modelsCard(_ result: QwenCodeUsageResult) -> some View {
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
                                Text("\(Fmt.tokensShort(model.totalTokens)) · \(Fmt.int(model.messageCount)) 请求")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            QuotaBar(progress: Double(model.totalTokens) / Double(maximum), tint: Theme.qwen)
                        }
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        SourcePrivacyCard(text: "仅只读 ~/.qwen/usage_record.jsonl 中的 Session、模型、时间与 Token 聚合字段；不读取对话、代码、工具参数或凭据，也不会上传。")
    }
}
