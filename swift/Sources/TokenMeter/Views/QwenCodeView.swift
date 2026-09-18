import Charts
import SwiftUI

// Qwen Code 只读取官方本地聚合文件，不打开 chats 对话记录。
struct QwenCodeView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let result = state.qwen.result {
                    todayCard(result)
                    hourlyCard(result)
                    weekCard(result)
                    modelsCard(result)
                    privacyCard
                } else if state.qwen.loading {
                    SourceStateView(loading: true, message: "正在读取…")
                } else {
                    SourceStateView(message: state.qwen.error ?? "未找到 Qwen Code 本地数据")
                }
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
                HStack(spacing: 10) {
                    tokenPart("新输入", today?.inputTokens ?? 0, Theme.miss)
                    tokenPart("缓存读取", today?.cachedInputTokens ?? 0, Theme.hit)
                    tokenPart("输出", today?.outputTokens ?? 0, Theme.response)
                    tokenPart("推理", today?.reasoningTokens ?? 0, Theme.qwen)
                }
            }
        }
    }

    private func tokenPart(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(color)
            Text(Fmt.tokensShort(value)).font(.system(size: 11, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hourlyCard(_ result: QwenCodeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日分时（Token）", systemImage: "clock")
                    .font(.system(size: 12, weight: .semibold))
                SourceHourChart(
                    bars: result.todayHours.map { .init(hour: $0.hour, tokens: $0.totalTokens) },
                    color: Theme.qwen
                )
                Text("Qwen 在 Session 结束时写入聚合记录，因此小时归属按 Session 结束时间。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func weekCard(_ result: QwenCodeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近 7 天 Token", systemImage: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                Chart(result.days) { day in
                    BarMark(x: .value("日期", Fmt.mmdd(day.date)), y: .value("缓存读取", day.cachedInputTokens))
                        .foregroundStyle(by: .value("类型", "缓存读取"))
                    BarMark(x: .value("日期", Fmt.mmdd(day.date)), y: .value("新输入", day.inputTokens))
                        .foregroundStyle(by: .value("类型", "新输入"))
                    BarMark(x: .value("日期", Fmt.mmdd(day.date)), y: .value("输出", day.outputTokens))
                        .foregroundStyle(by: .value("类型", "输出"))
                    BarMark(x: .value("日期", Fmt.mmdd(day.date)), y: .value("推理", day.reasoningTokens))
                        .foregroundStyle(by: .value("类型", "推理"))
                }
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
