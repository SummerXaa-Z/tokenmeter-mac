import Charts
import SwiftUI

// Copilot CLI 面板展示官方 session.shutdown 的本地聚合。运行中的会话尚未
// 持久化 shutdown，因此会在正常退出/落盘后出现，不尝试读取账号或远端配额。
struct CopilotView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let result = state.copilot.result {
                    todayCard(result)
                    weekChartCard(result)
                    modelsCard(result)
                    outputCard(result)
                    privacyCard
                } else if state.copilot.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error = state.copilot.error {
                    Text(error)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 60).padding(.horizontal, 20)
                } else {
                    Text("未找到 GitHub Copilot CLI 本地用量")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
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
            onBack: onBack,
            onRefresh: { Task { await state.loadCopilot(force: true) } },
            onSettings: onSettings
        )
    }

    private func todayCard(_ result: CopilotUsageResult) -> some View {
        let today = result.today
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日已结束会话", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 0) {
                    SourceMetric(title: "Token", value: Fmt.tokensShort(today?.totalTokens ?? 0))
                    SourceMetric(title: "消息", value: "\(today?.messageCount ?? 0)")
                    SourceMetric(title: "Skills", value: "\(today?.skillCount ?? 0)")
                    SourceMetric(title: "新增行", value: "\(today?.linesAdded ?? 0)")
                }
                Divider()
                Text("近 7 天 \(Fmt.tokensShort(result.weekTotal)) tokens · \(result.weekSessions) 个会话 · 缓存命中 \(cacheRateText(result))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func cacheRateText(_ result: CopilotUsageResult) -> String {
        let cached = result.days.reduce(0) { $0 + $1.cachedInputTokens }
        let prompt = result.days.reduce(0) {
            $0 + $1.inputTokens + $1.cachedInputTokens + $1.cacheWriteTokens
        }
        guard prompt > 0 else { return "—" }
        return String(format: "%.0f%%", Double(cached) / Double(prompt) * 100)
    }

    private func weekChartCard(_ result: CopilotUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近 7 天 Token（按会话结束日）", systemImage: "chart.bar")
                    .font(.system(size: 12, weight: .semibold))
                Chart(result.days) { day in
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
                .chartForegroundStyleScale([
                    "缓存读取": Theme.hit,
                    "缓存写入": Theme.copilot.opacity(0.65),
                    "新输入": Theme.miss,
                    "输出": Theme.response,
                ])
                .chartLegend(position: .bottom, spacing: 4)
                .tokenYAxis()
                .frame(height: 150)
            }
        }
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
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(Fmt.tokensShort(model.totalTokens)) · \(model.requestCount) 请求")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(model.totalTokens), total: Double(maximum))
                                .tint(Theme.copilot)
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
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text("+\(result.weekLinesAdded) / −\(result.weekLinesRemoved) 行")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                if result.skills.isEmpty {
                    Text("暂无 skill.invoked 记录")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(result.skills.prefix(5)) { skill in
                        HStack {
                            Text(skill.name)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("\(skill.invocationCount) 次")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("代码行是 session 内工具变更累计，不等于 Git 最终合入行数。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private var privacyCard: some View {
        SourcePrivacyCard(text: "只读取本机最新 session.shutdown 聚合及事件类型；不读取、展示或上报提示词、回复、代码正文、文件路径和账号凭据。运行中会话需在落盘汇总后计入。")
    }
}
