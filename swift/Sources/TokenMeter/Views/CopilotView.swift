import Charts
import SwiftUI

// Copilot CLI 面板展示官方 session.shutdown 的本地聚合。运行中的会话尚未
// 持久化 shutdown，因此会在正常退出/落盘后出现，不尝试读取账号或远端配额。
struct CopilotView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.usageNow) private var now
    @Environment(\.sourceUsageRange) private var usageRange
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                ScopedSourceUsageCard(source: .copilot)
                SourceCollectionContent(cache: state.copilot, emptyMessage: "未找到 GitHub Copilot CLI 本地数据") { result in
                    if usageRange == nil { todayCard(result) }
                    weekChartCard(result)
                    if usageRange == nil { modelsCard(result) }
                    outputCard(result)
                    privacyCard
                }
                SourceAPICostCard(source: .copilot, liveDayModels: state.copilot.result?.dayModels)
                SourceWeekCompareCard(source: .copilot)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task { await state.loadCopilot() }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "chevron.left.forwardslash.chevron.right",
            title: "GitHub Copilot Monitor",
            color: Theme.copilot,
            process: state.copilot.proc,
            refreshing: state.copilot.loading,
            onBack: onBack,
            onRefresh: { Task { await state.loadCopilot(force: true) } },
            onSettings: onSettings
        )
    }

    private func todayCard(_ result: CopilotUsageResult) -> some View {
        let today = result.day(on: DateUtil.key(now))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日已结束会话", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 0) {
                    SourceMetric(title: "Token", value: (today?.totalTokens).map(Fmt.tokensShort) ?? "—")
                    SourceMetric(title: "消息", value: (today?.messageCount).map(Fmt.int) ?? "—")
                    SourceMetric(title: "Skills", value: (today?.skillCount).map(Fmt.int) ?? "—")
                    SourceMetric(title: "新增行", value: (today?.linesAdded).map(Fmt.int) ?? "—")
                }
                Divider()
                Text("近 7 天 \(Fmt.tokensShort(result.weekTotal)) tokens · \(Fmt.int(result.weekSessions)) 个会话 · 缓存命中 \(cacheRateText(result))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func cacheRateText(_ result: CopilotUsageResult) -> String {
        let cached = result.days.reduce(0) { $0 + $1.cachedInputTokens }
        let prompt = result.days.reduce(0) {
            $0 + $1.inputTokens + $1.cachedInputTokens + $1.cacheWriteTokens
        }
        guard prompt > 0 else { return "—" }
        return Fmt.percent(Double(cached) / Double(prompt) * 100)
    }

    private func weekChartCard(_ result: CopilotUsageResult) -> some View {
        SourceTrendCard(
            source: .copilot,
            weekDays: result.days.map { day in
                .init(date: day.date, parts: [
                    ("缓存读取", day.cachedInputTokens, Theme.hit),
                    ("缓存写入", day.cacheWriteTokens, Theme.miss),
                    ("新输入", day.inputTokens, Theme.input),
                    ("输出", day.outputTokens + day.reasoningTokens, Theme.response),
                ])
            },
            liveDayModels: result.dayModels, initialRange: usageRange)
    }

    private func modelsCard(_ result: CopilotUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("模型分布（近 7 天）", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                if result.models.isEmpty {
                    Text("暂无已结束会话数据")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    let maximum = max(result.models.first?.totalTokens ?? 0, 1)
                    ForEach(result.models.prefix(6)) { model in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(model.model)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(Fmt.tokensShort(model.totalTokens)) · \(Fmt.int(model.requestCount)) 请求")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            QuotaBar(progress: Double(model.totalTokens) / Double(maximum), tint: Theme.copilot)
                        }
                    }
                }
            }
        }
    }

    private func outputCard(_ result: CopilotUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("AI 动手与 Skills（近 7 天）", systemImage: "hammer")
                    .font(.system(size: 12, weight: .semibold))
                HStack {
                    Text("代码变更")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("+\(result.weekLinesAdded) / −\(result.weekLinesRemoved) 行")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                if result.skills.isEmpty {
                    Text("暂无 skill.invoked 记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(result.skills.prefix(5)) { skill in
                        HStack {
                            Text(skill.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("\(skill.invocationCount) 次")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("代码行是 session 内工具变更累计，不等于 Git 最终合入行数。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var privacyCard: some View {
        SourcePrivacyCard(text: "只读取本机最新 session.shutdown 聚合及事件类型；不读取、展示或上报提示词、回复、代码正文、文件路径和账号凭据。运行中会话需在落盘汇总后计入。")
    }
}
