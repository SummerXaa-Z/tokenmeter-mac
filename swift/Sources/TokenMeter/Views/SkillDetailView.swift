import SwiftUI
import Charts
import AppKit

// Skill 下钻页：从总览 Skills 榜点入。范围统计直接携带所点行的 Entry
//（与点击时榜单所见完全一致，不重算），近 13 周逐周调用次数为全宽柱图
// ——与榜内迷你条同一条 SkillUsageTrend 管线（周一锚定、旧 → 新、
// 空周计 0）；悬停查单周。
struct SkillDetailView: View {
    let entry: PersonalSkillRankings.Entry
    // 与总览所选范围一致的口径说明（数字本身来自 Entry）
    let rangeTitle: String
    let onBack: () -> Void
    // 来源筛选与榜单、周走势、导出共同携带，nil 为全部来源。
    var sourceFilter: HistorySource? = nil
    // 保留点击时的总览来源开关，近 13 周不能混入已关闭来源。
    var enabledSources: [HistorySource]? = nil
    // 渲染夹具：注入确定性的近 13 周序列（真实取数来自本机留存与实时
    // 采集，离屏渲染不可预测）；nil 时按实时 + 留存自算
    var injectedWeekly: [(weekOf: String, count: Int)]? = nil
    // 渲染夹具：注入固定的导出反馈文案（离屏渲染无法模拟保存面板）
    var previewExportStatus: String? = nil
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    @State private var hoverWeek: String?
    // 导出完成后的行内反馈（「已导出 <文件名> · 时刻」）
    @State private var exportStatus: String?

    private var weekly: [(weekOf: String, count: Int)]? {
        if let injectedWeekly { return injectedWeekly }
        return OverviewRankingsCard.weeklySkillCounts(
            name: entry.name, filteredBy: sourceFilter,
            enabledSources: enabledSources,
            liveSkills: OverviewRankingsCard.liveDaySkills(state),
            persisted: historyReader.snapshot.models)
    }

    private var scopedRangeTitle: String {
        guard let sourceFilter else { return rangeTitle }
        return "\(rangeTitle) · 已筛 \(sourceFilter.overviewName)"
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            summaryCard
            if let weekly {
                trendCard(weekly)
            } else {
                SourceStateView(
                    message: "近 13 周暂无该 Skill 的留存调用记录（范围统计见上，调用可能早于近 13 周）")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "sparkles",
            title: entry.name,
            color: Theme.brand,
            onBack: onBack)
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Skill 调用", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 16) {
                    stat("范围调用次数", "\(Fmt.int(entry.invocationCount)) 次")
                    stat("范围占比", "\(Int((entry.share * 100).rounded()))%")
                    stat("来源数", "\(entry.sources.count)")
                }
                Divider()
                Text("来源拆解").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(entry.sources) { sourceCount in
                    HStack {
                        Circle().fill(sourceCount.source.overviewColor)
                            .frame(width: 8, height: 8)
                        Text(sourceCount.source.overviewName)
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(Fmt.int(sourceCount.invocationCount)) 次")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("范围数字与 Skills 榜一致（\(scopedRangeTitle)）；只认明确调用证据，普通消息提及不计入。")
                    .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trendCard(_ weekly: [(weekOf: String, count: Int)]) -> some View {
        let points = weekly.map { week in
            (label: Self.weekLabel(week.weekOf), weekOf: week.weekOf, count: week.count)
        }
        // 悬停对准的周（x 轴选中的是周标签）；未悬停显示最新一周
        let active = points.first { $0.label == hoverWeek } ?? points.last
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("近 13 周调用次数", systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // 与热力图/模型榜/Skills 榜导出同款入口；卡只在有
                    // 13 周数据时出现；共享历史尚未成功读取时禁止导出。
                    Button {
                        exportCSV(weekly)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("导出近 13 周走势 CSV（逐周次数，附范围与来源口径行）")
                    .accessibilityLabel("导出 Skill 走势 CSV")
                    .disabled(!historyReader.canUseSnapshot)
                }
                HStack(spacing: 6) {
                    Text(active?.label ?? "")
                        .font(Theme.rowTitleFont)
                        .lineLimit(1)
                    Text(active.map { Self.countText($0.count) } ?? "")
                        .font(Theme.rowTitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        BarMark(
                            x: .value("周", point.label),
                            y: .value("次数", point.count))
                            .foregroundStyle(Theme.brand.opacity(0.85))
                            .cornerRadius(2)
                    }
                    HoverDateRule(date: hoverWeek)
                }
                .chartXSelection(value: $hoverWeek)
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel()
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 140)
                Text("按自然周聚合（周一为界，旧 → 新），本周为进行中；与榜内迷你条同一条取数管线，无调用的周计 0。")
                    .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 导出近 13 周走势 CSV；保存面板流程与模型榜/Skills 榜导出同款，
    /// 写盘失败弹系统错误框。来源拆解复用榜内悬停文案。
    private func exportCSV(_ weekly: [(weekOf: String, count: Int)]) {
        guard historyReader.canUseSnapshot else {
            exportStatus = historyReader.unavailableMessage
            return
        }
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出 Skill 走势 CSV",
            filename: SkillDetailCSVExport.suggestedFilename(skill: entry.name)
        ) {
            SkillDetailCSVExport.makeCSV(
                entry: entry,
                weekly: weekly,
                sourceNote: OverviewRankingsCard.hoverSkillText(for: entry),
                scopeTitle: scopedRangeTitle
            )
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }

    /// 周标签：与榜内迷你条悬停文案同一写法（mmdd + 周）
    static func weekLabel(_ weekOf: String) -> String {
        "\(Fmt.mmdd(weekOf))周"
    }

    /// 单周次数文案：与榜内 skillWeekText 的次数段一致，零周明示无调用
    static func countText(_ count: Int) -> String {
        count > 0 ? "· \(Fmt.int(count)) 次" : "· 无调用"
    }
}
