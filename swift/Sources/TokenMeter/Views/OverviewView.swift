import SwiftUI
import Charts

// 总览：四源今日合计 + 近 30 天 token 趋势（历史留存）。
// 今日数仅含有按日数据的三源（DeepSeek/Claude/Codex）；Cursor 接口只给
// 周期聚合、无法切出"今天"，单列「本期」不计入今日合计。
struct OverviewView: View {
    @EnvironmentObject var state: AppState
    var onSettings: () -> Void
    @State private var history: [HistoryStore.DayPoint] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                todayCard
                trendCard
                if let cursor = state.cursor.result {
                    cursorCard(cursor)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        // 触发全源加载（命中缓存即秒回），再读历史
        .task {
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await state.loadClaude() }
                g.addTask { await state.loadCodex() }
                g.addTask { await state.loadCursor() }
            }
            if state.deepseekEnabled { state.refreshAll() }
            history = HistoryStore.recent(30)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text("总览")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            iconButton("arrow.clockwise") {
                Task {
                    await withTaskGroup(of: Void.self) { g in
                        g.addTask { await state.loadClaude(force: true) }
                        g.addTask { await state.loadCodex(force: true) }
                        g.addTask { await state.loadCursor(force: true) }
                    }
                    if state.deepseekEnabled { state.refreshAll() }
                    history = HistoryStore.recent(30)
                }
            }
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

    // MARK: - 今日全源合计

    private var deepseekToday: Int {
        state.usage?.days.first { $0.date == DateUtil.today() }?.totalTokens ?? 0
    }
    // cc 路由到 deepseek 后端的 token 已计入 DeepSeek 官方源，合计时从 Claude
    // 侧扣掉避免双算（Claude tab 自身仍显示含后端的完整用量，不受影响）
    private var claudeBackendDup: Int { state.claude.result?.todayDeepseekBackend ?? 0 }
    private var claudeToday: Int { state.claude.result?.today?.totalTokens ?? 0 }
    private var claudeTodayNet: Int { max(claudeToday - claudeBackendDup, 0) }
    private var codexToday: Int { state.codex.result?.today?.totalTokens ?? 0 }
    private var cursorToday: Int { state.cursor.result?.todayTokens ?? 0 }
    private var todayTotal: Int { deepseekToday + claudeTodayNet + codexToday + cursorToday }

    private var todayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("今日全源合计", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(Fmt.tokensShort(todayTotal)) tokens")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brand)
                HStack(spacing: 0) {
                    srcStat("DeepSeek", deepseekToday, Theme.brand)
                    srcStat("Claude", claudeTodayNet, Theme.claude)
                    srcStat("Codex", codexToday, Theme.codex)
                    srcStat("Cursor", cursorToday, Theme.cursor)
                }
                if claudeBackendDup > 0 {
                    Text("已扣除 cc 经 DeepSeek 后端的 \(Fmt.tokensShort(claudeBackendDup))（与 DeepSeek 源重叠，避免双算）")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func srcStat(_ name: String, _ tokens: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(Fmt.tokensShort(tokens))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 近 30 天趋势

    private struct Seg: Identifiable {
        let id = UUID()
        let date: String
        let source: String
        let tokens: Int
    }

    private var segments: [Seg] {
        history.flatMap { p -> [Seg] in
            [(HistorySource.deepseek, "DeepSeek"), (.claude, "Claude"),
             (.codex, "Codex"), (.cursor, "Cursor")]
                .compactMap { (src, name) in
                    let v = p.bySource[src] ?? 0
                    return v > 0 ? Seg(date: Fmt.mmdd(p.date), source: name, tokens: v) : nil
                }
        }
    }

    private var trendCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("近 30 天 Token 趋势", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    let total = history.reduce(0) { $0 + $1.total }
                    Text("合计 \(Fmt.tokensShort(total))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if segments.isEmpty {
                    Text("暂无历史数据（每次刷新后逐日累积）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Chart(segments) { s in
                        BarMark(
                            x: .value("日期", s.date),
                            y: .value("Token", s.tokens))
                        .foregroundStyle(by: .value("源", s.source))
                        .cornerRadius(1)
                    }
                    .chartForegroundStyleScale([
                        "DeepSeek": Theme.brand, "Claude": Theme.claude,
                        "Codex": Theme.codex, "Cursor": Theme.cursor,
                    ])
                    .chartLegend(position: .bottom, spacing: 4)
                    // 30 天标签太密，每 5 天一标
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisGridLine(); AxisTick(); AxisValueLabel()
                        }
                    }
                    .tokenYAxis()
                    .frame(height: 160)
                }
                if let cost = monthCostText {
                    Divider()
                    Text(cost).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // 30 天 DeepSeek 成本合计（目前唯一带单价的源）
    private var monthCostText: String? {
        let cost = history.reduce(0.0) { $0 + $1.cost }
        guard cost > 0 else { return nil }
        return "近 30 天 DeepSeek 成本 \(Fmt.money(cost))"
    }

    // MARK: - Cursor 本期（无按日数据，单列）

    private func cursorCard(_ r: CursorUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Cursor 本订阅周期", systemImage: "cursorarrow.rays")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("$\(String(format: "%.2f", r.totalCostCents / 100))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.cursor)
                }
                Text("本期累计 \(Fmt.tokensShort(r.totalTokens)) tokens（今日合计与趋势已含 Cursor 当日用量）")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
