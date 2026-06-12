import SwiftUI
import Charts

// Claude 用量面板：今日用量 + 7 天柱图 + 按模型分布。
// 数据全部来自本地 ~/.claude/projects，刷新即重扫（带缓存）。
struct ClaudeView: View {
    var onSettings: () -> Void
    @State private var result: ClaudeUsageResult?
    @State private var proc = ProcessStatus.Snapshot(running: false, count: 0)
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let r = result {
                    todayCard(r)
                    hoursCard(r)
                    weekChartCard(r)
                    weekCompareCard(r)
                    modelCard(r)
                    projectCard(r)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    Text("未找到 Claude 本地数据（~/.claude/projects）")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.claude)
            Text("Claude Monitor")
                .font(.system(size: 15, weight: .bold))
            RunningBadge(snapshot: proc)
            Spacer()
            iconButton("arrow.clockwise") { Task { await reload() } }
            iconButton("gearshape") { onSettings() }
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    func reload() async {
        loading = true
        proc = ProcessStatus.claude()
        let r = await Task.detached(priority: .userInitiated) { ClaudeUsage.load() }.value
        result = r
        loading = false
    }

    // MARK: - 今日
    private func todayCard(_ r: ClaudeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日用量", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                let t = r.today
                HStack(spacing: 0) {
                    stat("Token", Fmt.tokensShort(t?.totalTokens ?? 0))
                    stat("请求", "\(t?.messageCount ?? 0)")
                    stat("缓存命中", t?.cacheHitRate.map { String(format: "%.0f%%", $0) } ?? "—")
                    stat("输出", Fmt.tokensShort(t?.outputTokens ?? 0))
                }
                Divider()
                HStack {
                    Text("近 7 天合计 \(Fmt.tokensShort(r.weekTotal)) tokens · \(r.weekMessages) 次请求")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 今日分时
    private func hoursCard(_ r: ClaudeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("今日分时（Token）", systemImage: "clock")
                    .font(.system(size: 12, weight: .semibold))
                Chart(r.todayHours) { h in
                    BarMark(
                        x: .value("时", h.hour),
                        y: .value("Token", h.totalTokens),
                        width: .ratio(0.7))
                    .foregroundStyle(Theme.claude.opacity(h.totalTokens > 0 ? 0.9 : 0.2))
                }
                .chartXScale(domain: -0.5...23.5)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                        AxisValueLabel { if let h = v.as(Int.self) { Text("\(h)时") } }
                    }
                }
                .frame(height: 70)
            }
        }
    }

    // MARK: - 7 天柱图
    private func weekChartCard(_ r: ClaudeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近 7 天 Token", systemImage: "chart.bar")
                    .font(.system(size: 12, weight: .semibold))
                Chart(r.days) { day in
                    BarMark(
                        x: .value("日期", Fmt.mmdd(day.date)),
                        y: .value("缓存读取", day.cacheReadTokens))
                    .foregroundStyle(by: .value("类型", "缓存读取"))
                    BarMark(
                        x: .value("日期", Fmt.mmdd(day.date)),
                        y: .value("缓存写入", day.cacheCreationTokens))
                    .foregroundStyle(by: .value("类型", "缓存写入"))
                    BarMark(
                        x: .value("日期", Fmt.mmdd(day.date)),
                        y: .value("新输入", day.inputTokens))
                    .foregroundStyle(by: .value("类型", "新输入"))
                    BarMark(
                        x: .value("日期", Fmt.mmdd(day.date)),
                        y: .value("输出", day.outputTokens))
                    .foregroundStyle(by: .value("类型", "输出"))
                }
                .chartForegroundStyleScale([
                    "缓存读取": Theme.hit, "缓存写入": Theme.claude,
                    "新输入": Theme.miss, "输出": Theme.response,
                ])
                .chartLegend(position: .bottom, spacing: 4)
                .frame(height: 150)
            }
        }
    }

    // MARK: - 周趋势（本周 vs 上周）
    private func weekCompareCard(_ r: ClaudeUsageResult) -> some View {
        let c = r.weekCompare
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("周趋势（本周 vs 上周）", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                compareRow("Token", Fmt.tokensShort(c.thisTotalTokens),
                           Fmt.tokensShort(c.lastTotalTokens), c.totalChange)
                compareRow("请求", "\(c.thisMessageCount)",
                           "\(c.lastMessageCount)", c.messageChange)
                compareRow("输出", Fmt.tokensShort(c.thisOutputTokens),
                           Fmt.tokensShort(c.lastOutputTokens), c.outputChange)
            }
        }
    }

    // 本周值列定宽，三行的"上周"列才能对齐（数字长短不一）
    private func compareRow(_ title: String, _ cur: String, _ prev: String,
                            _ change: Double?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 40, alignment: .leading)
            Text(cur)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 52, alignment: .leading)
            Text("上周 \(prev)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            changeBadge(change)
        }
    }

    // 用量涨=花钱多标红，降=省钱标绿；无基期显示 —
    private func changeBadge(_ change: Double?) -> some View {
        Group {
            if let change {
                Text("\(change >= 0 ? "↑" : "↓") \(String(format: "%.0f%%", abs(change)))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(change >= 0 ? .red : .green)
            } else {
                Text("—")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 模型分布（7 天窗口）
    private func modelCard(_ r: ClaudeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("模型分布（近 7 天）", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                if r.models.isEmpty {
                    Text("暂无数据").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    let maxTotal = max(r.models.first?.totalTokens ?? 0, 1)
                    ForEach(r.models.prefix(5)) { m in
                        barRow(m.model, m.totalTokens, m.messageCount, maxTotal)
                    }
                }
            }
        }
    }

    // MARK: - 项目分布（7 天窗口）
    private func projectCard(_ r: ClaudeUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("项目分布（近 7 天）", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
                if r.projects.isEmpty {
                    Text("暂无数据").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    let maxTotal = max(r.projects.first?.totalTokens ?? 0, 1)
                    ForEach(r.projects.prefix(6)) { p in
                        barRow(p.project, p.totalTokens, p.messageCount, maxTotal)
                    }
                }
            }
        }
    }

    private func barRow(_ name: String, _ total: Int, _ count: Int, _ maxTotal: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Fmt.tokensShort(total)) · \(count) 次")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(total), total: Double(maxTotal))
                .tint(Theme.claude)
        }
    }
}
