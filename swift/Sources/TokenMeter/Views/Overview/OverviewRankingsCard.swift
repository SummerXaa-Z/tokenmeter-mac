import SwiftUI
import AppKit

// 模型榜单价小抄：给榜上的模型名配一行当前生效的参考单价
// （输入 / 输出，每百万 tokens）。缺价模型不标注——缺价的汇报入口
// 在 API 等价卡的复制按钮，榜单保持安静。
enum ModelPriceCheatSheet {
    static func caption(
        model: String,
        estimator: APICostEstimator = APIReferencePricingCatalog.estimator,
        on date: String = APIReferencePricingCatalog.observedAt
    ) -> String? {
        guard let snapshot = estimator.priceSnapshot(model: model, on: date) else {
            return nil
        }
        let symbol = snapshot.currency == "CNY" ? "¥" : "$"
        return "\(symbol)\(trim(snapshot.perMillion.newInput)) / \(symbol)\(trim(snapshot.perMillion.output)) /M"
    }

    // 去掉尾零：4 → "4"，2.4400 → "2.44"，0.0098 → "0.0098"
    private static func trim(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

struct OverviewRankingsCard: View {
    let rankings: PersonalUsageRankings
    let skillRankings: PersonalSkillRankings
    let range: UsageHistoryRange
    var coverageNote: String? = nil
    // 模型行点击下钻到详情页；默认空实现（渲染/预览可省）
    var onOpenModel: (HistorySource, String) -> Void = { _, _ in }
    // Skill 行点击下钻到详情页（近 13 周走势与来源拆解）
    var onOpenSkill: (PersonalSkillRankings.Entry, HistorySource?, [HistorySource]) -> Void = { _, _, _ in }
    // 渲染夹具:强制某行进入悬停态(行高亮 + 说明行用固定文案),
    // 离屏渲染无法模拟指针悬停
    var previewRowId: String? = nil
    var previewTextOverride: String? = nil
    // 渲染夹具:强制某个 Skill 行进入悬停态(Skill 榜纯内存聚合,
    // 悬停文案由夹具数据确定性算出,无需 override)
    var previewSkillId: String? = nil
    // 渲染夹具:强制 Skills 榜来源筛选(离屏渲染无法模拟点徽标)
    var previewSkillSourceFilter: HistorySource? = nil
    // 渲染夹具:注入确定性的近 30 天日序列(sparkline 真实取数
    // 来自本机按天留存,离屏渲染不可预测);日期随序列携带,
    // 悬停查日文案才能显示对准日
    var sparklineFor: ((HistorySource, String) -> [(date: String, tokens: Int)])? = nil
    // 渲染夹具:强制某行迷你柱进入某日悬停态(说明行显示单日文案)
    var previewSparkDay: (source: HistorySource, model: String, dayIndex: Int)? = nil
    // 渲染夹具:注入确定性的 Skill 近 13 周序列(真实取数来自
    // 本机留存与实时采集,离屏渲染不可预测)
    var skillSparkFor: ((String, HistorySource?) -> [(weekOf: String, count: Int)])? = nil
    // 渲染夹具:强制某行迷你条进入某周悬停态(说明行显示单周文案)
    var previewSkillSparkWeek: (name: String, weekIndex: Int)? = nil
    // 渲染夹具:强制排序档(离屏渲染无法模拟点选);
    // 等价/近7天档的排序值也可注入,渲染机真实留存不可预测
    var previewSort: ModelSort? = nil
    var sortValueFor: ((HistorySource, String, ModelSort) -> Double)? = nil
    // 渲染夹具:注入固定的导出反馈文案(离屏渲染无法模拟保存面板)
    var previewExportStatus: String? = nil
    @EnvironmentObject private var state: AppState
    @State private var hoverEntry: PersonalUsageRankings.ModelEntry?
    @State private var hoverSkill: PersonalSkillRankings.Entry?
    // Skills 榜来源筛选:点行内来源徽标只看该来源的 Skill,再点还原
    @State private var skillSourceFilter: HistorySource?
    // 迷你柱悬停对准的日序号(指针在柱图上时优先于行悬停文案)
    @State private var sparkDay: (source: HistorySource, model: String, dayIndex: Int)?
    // Skill 迷你条悬停对准的周序号
    @State private var skillSparkWeek: (name: String, weekIndex: Int)?
    @State private var sort: ModelSort = .usage
    // 导出完成后的行内反馈(模型榜与 Skills 榜共用一行,后导出的覆盖)
    @State private var exportStatus: String?

    /// 模型榜排序档:用量=所选范围 Token(默认);等价/近7天来自
    /// 近 30 天明细留存(与悬停数字同管线,缺价模型的等价按 0 沉底)
    enum ModelSort: String, CaseIterable {
        case usage = "用量"
        case usd = "等价"
        case week = "近7天"

        var help: String {
            switch self {
            case .usage: return "按所选范围 Token 合计排序（默认）"
            case .usd: return "按近 30 天 API 等价美元排序（缺价模型沉底）"
            case .week: return "按近 7 天 Token 排序（近 7 天无用量的行沉底）"
            }
        }
    }

    private var activeSort: ModelSort { previewSort ?? sort }

    private func displayedModelValue(_ entry: PersonalUsageRankings.ModelEntry) -> Double? {
        if activeSort == .usage { return Double(entry.totalTokens) }
        if let sortValueFor {
            let value = sortValueFor(entry.source, entry.model, activeSort)
            return value >= 0 ? value : nil
        }
        guard let summary = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: CodingModelDetailView.liveDayModels(entry.source, state: state),
            windowDays: activeSort == .week ? 7 : 30) else { return nil }
        if activeSort == .usd {
            return (summary.coverage ?? 0) > 0 ? summary.totalUSD : nil
        }
        return Double(summary.tally.total)
    }

    /// 稳定降序排序(键相等保持原顺序)。纯函数供单元测试。
    static func sortedBySortValue(
        _ models: [PersonalUsageRankings.ModelEntry],
        value: (PersonalUsageRankings.ModelEntry) -> Double
    ) -> [PersonalUsageRankings.ModelEntry] {
        models.enumerated().sorted { lhs, rhs in
            let left = value(lhs.element)
            let right = value(rhs.element)
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 排序值与真实明细共用取数入口，测试可传入确定性的本地聚合数据。
    static func modelSortValue(
        for entry: PersonalUsageRankings.ModelEntry,
        sort: ModelSort,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today()
    ) -> Double {
        if sort == .usage { return Double(entry.totalTokens) }
        guard let summary = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: liveDayModels, persisted: persisted,
            todayKey: todayKey, windowDays: sort == .week ? 7 : 30)
        else { return -1 }
        return sort == .usd ? summary.totalUSD : Double(summary.tally.total)
    }

    /// 当前排序档下的完整榜单(排序作用于全量,再由调用方取前 5,
    /// 避免「范围用量第 6 名」在别的维度下进不了榜)
    private var sortedModels: [PersonalUsageRankings.ModelEntry] {
        if activeSort == .usage { return rankings.models }
        return Self.sortedBySortValue(rankings.models) { entry in
            displayedModelValue(entry) ?? -1
        }
    }

    /// 迷你趋势柱的布局矩形(底对齐):峰值满高、零值零高、
    /// 非零值保底 1.5pt 可见。纯函数供单元测试。
    static func sparklineBars(values: [Int], width: CGFloat, height: CGFloat) -> [CGRect] {
        guard !values.isEmpty, width > 0, height > 0 else { return [] }
        let count = values.count
        let gap: CGFloat = count > 1 ? 0.5 : 0
        let barWidth = max((width - CGFloat(count - 1) * gap) / CGFloat(count), 1)
        let peak = max(values.max() ?? 0, 1)
        return values.enumerated().map { index, value in
            let x = CGFloat(index) * (barWidth + gap)
            let barHeight: CGFloat = value <= 0
                ? 0
                : max(CGFloat(value) / CGFloat(peak) * height, 1.5)
            return CGRect(x: x, y: height - barHeight, width: barWidth, height: barHeight)
        }
    }

    /// 指针 x 落在第几根柱(与 sparklineBars 同一套宽度分配;
    /// 超出柱图范围返回 nil,末柱右半缝隙并入末柱)。纯函数供单元测试。
    static func sparklineIndex(atX x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0, width > 0, x >= 0, x <= width else { return nil }
        let gap: CGFloat = count > 1 ? 0.5 : 0
        let barWidth = max((width - CGFloat(count - 1) * gap) / CGFloat(count), 1)
        return min(Int(x / (barWidth + gap)), count - 1)
    }

    /// 悬停单柱的说明行文案:日期(周几) + 当日 Token;零值日明示无用量。
    /// 纯函数供单元测试。
    static func sparklineDayText(date: String, tokens: Int, calendar: Calendar = .current) -> String {
        var lead = Fmt.mmdd(date)
        if let day = DateUtil.date(from: date) {
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let weekday = calendar.component(.weekday, from: day)
            if names.indices.contains(weekday - 1) { lead += "（\(names[weekday - 1])）" }
        }
        return lead + " · " + (tokens > 0 ? Fmt.tokensShort(tokens) : "无用量")
    }

    static func sparklineHoverText(
        source: HistorySource, model: String, dayIndex: Int,
        models: [PersonalUsageRankings.ModelEntry],
        seriesFor: (HistorySource, String) -> [(date: String, tokens: Int)]?
    ) -> String? {
        guard let entry = models.first(where: { $0.source == source && $0.model == model }),
              let series = seriesFor(entry.source, model),
              series.indices.contains(dayIndex) else { return nil }
        let item = series[dayIndex]
        return sparklineDayText(date: item.date, tokens: item.tokens)
    }

    /// 悬停说明行文案:近 7 / 30 天 Token、30 天 API 等价与活跃天数。
    /// 近 30 天无用量时明示(榜单「全部」范围会列出只剩更早历史的模型)。
    static func hoverPreviewText(
        week: CodingModelDetail.Summary?, month: CodingModelDetail.Summary?
    ) -> String {
        guard let month else {
            return "近 30 天无用量（该行来自更早历史），点进详情页看 90 天"
        }
        var parts = [
            "近 7 天 \(Fmt.tokensShort(week?.tally.total ?? 0))",
            "近 30 天 \(Fmt.tokensShort(month.tally.total))",
        ]
        if (month.coverage ?? 1) <= 0 {
            parts.append("30 天 API 等价缺价")
        } else {
            parts.append("30 天 API 等价 \(Fmt.usd(month.totalUSD))")
        }
        parts.append("活跃 \(month.activeDays) 天")
        return parts.joined(separator: " · ")
    }

    /// Skills 榜悬停说明行:该 Skill 各来源的调用次数(已按次数降序)。
    static func hoverSkillText(for entry: PersonalSkillRankings.Entry) -> String {
        let parts = entry.sources.map {
            "\($0.source.overviewName) \(Fmt.int($0.invocationCount)) 次"
        }
        guard !parts.isEmpty else { return "该 Skill 暂无调用记录" }
        return parts.joined(separator: " · ")
    }

    /// Skill 迷你条单周悬停的说明行文案:周一锚定周标签 + 当周次数。
    /// 纯函数供单元测试。
    static func skillWeekText(weekOf: String, count: Int) -> String {
        "\(Fmt.mmdd(weekOf))周 · " + (count > 0 ? "\(Fmt.int(count)) 次" : "无调用")
    }

    /// Skills 榜可见行:来源筛选后次数、占比和排序都按该来源重算。
    /// 纯函数供单元测试。
    static func skills(
        _ entries: [PersonalSkillRankings.Entry],
        filteredBy source: HistorySource?
    ) -> [PersonalSkillRankings.Entry] {
        PersonalSkillRankings.filteredEntries(entries, source: source)
    }

    /// 各来源实时采集的逐日 Skill 调用(与 dayModels 同窗口同语义)。
    /// Skill 下钻页与榜内迷你条共用(榜行点击进入详情)。
    static func liveDaySkills(
        _ state: AppState
    ) -> [HistorySource: [String: [String: Int]]] {
        [
            .claude: state.claude.result?.daySkills ?? [:],
            .codex: state.codex.result?.daySkills ?? [:],
            .copilot: state.copilot.result?.daySkills ?? [:],
        ]
    }

    /// Skill 迷你条的近 13 周逐周序列;夹具注入优先,断流返回 nil(不画)
    private func skillWeeklyCounts(name: String) -> [(weekOf: String, count: Int)]? {
        if let skillSparkFor { return skillSparkFor(name, activeSkillSourceFilter) }
        return Self.weeklySkillCounts(
            name: name, filteredBy: activeSkillSourceFilter,
            enabledSources: skillRankings.enabledSources,
            liveSkills: Self.liveDaySkills(state))
    }

    static func weeklySkillCounts(
        name: String,
        filteredBy source: HistorySource?,
        enabledSources: [HistorySource]? = nil,
        liveSkills: [HistorySource: [String: [String: Int]]],
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today()
    ) -> [(weekOf: String, count: Int)]? {
        return SkillUsageTrend.weeklyCounts(
            name: name, weeks: 13, sourceFilter: source,
            enabledSources: enabledSources, liveSkills: liveSkills,
            persisted: persisted, todayKey: todayKey)
    }

    /// 导出当前排序下的完整模型榜（不只界面前 5）为 CSV；列与悬停
    /// 数字同管线。保存面板流程与「设置 → 用量导出」同款，写盘失败
    /// 弹系统错误框。
    private func exportRankingsCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出模型榜 CSV"
        panel.nameFieldStringValue = ModelRankingCSVExport.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ModelRankingCSVExport.makeCSV(
                rows: exportRows,
                scopeTitle: range.scopeTitle,
                sortTitle: activeSort.rawValue
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出模型榜 CSV 失败"
            alert.runModal()
        }
    }

    /// 导出行:近 7/30 天与金额走悬停数字同一条下钻管线,断流或缺价
    /// 留空(不是 0);单价复用单价小抄的展示文案
    private var exportRows: [ModelRankingCSVExport.Row] {
        sortedModels.enumerated().map { index, entry in
            let live = CodingModelDetailView.liveDayModels(entry.source, state: state)
            let month = CodingModelDetail.summary(
                source: entry.source, model: entry.model,
                liveDayModels: live, windowDays: 30)
            let week = month == nil ? nil : CodingModelDetail.summary(
                source: entry.source, model: entry.model,
                liveDayModels: live, windowDays: 7)
            return ModelRankingCSVExport.Row(
                rank: index + 1,
                source: entry.source.overviewName,
                model: entry.model,
                rangeTokens: entry.totalTokens,
                sharePercent: entry.share,
                weekTokens: week?.tally.total,
                monthTokens: month?.tally.total,
                monthUSD: month.flatMap { summary in
                    (summary.coverage ?? 1) > 0 ? summary.totalUSD : nil
                },
                activeDays: month?.activeDays,
                priceNote: ModelPriceCheatSheet.caption(model: entry.model) ?? "")
        }
    }

    var body: some View {
        let values = Dictionary(uniqueKeysWithValues: rankings.models.map { ($0.id, displayedModelValue($0)) })
        let total = values.values.compactMap { $0 }.reduce(0, +)
        OverviewSection {
            VStack(alignment: .leading, spacing: 9) {
                Label("模型与 Skills", systemImage: "list.number")
                    .font(.system(size: 12, weight: .semibold))

                HStack {
                    Text("模型榜").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Picker("排序", selection: Binding(get: { activeSort }, set: { sort = $0 })) {
                        ForEach(ModelSort.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("模型榜排序")
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 132)
                    .help("用量 = \(range.scopeTitle)合计；等价 / 近7天来自近 30 天明细留存")
                    // 导出当前排序下的完整模型榜（不只前 5）为 CSV
                    Button {
                        exportRankingsCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(rankings.models.isEmpty)
                    .help("导出模型榜 CSV（当前排序的完整榜单）")
                    .accessibilityLabel("导出模型榜 CSV")
                }
                Text(activeSort == .usd ? "近 30 天 API 等价参考" : (activeSort == .week ? "近 7 天 Token 占比" : "\(range.scopeTitle) Token 占比"))
                    .font(Theme.footnoteFont).foregroundStyle(.secondary)
                if rankings.models.isEmpty {
                    empty("刷新任一本地用量来源后生成")
                } else {
                    ForEach(Array(sortedModels.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        Button {
                            onOpenModel(entry.source, entry.model)
                        } label: {
                            rankingRow(
                                name: entry.model,
                                source: entry.source,
                                value: values[entry.id] ?? nil,
                                share: activeSort == .usage ? entry.share : ((values[entry.id] ?? nil).flatMap { total > 0 ? $0 / total : nil }),
                                showsSource: true,
                                highlighted: previewId == entry.id,
                                sparkline: sparklineValues(source: entry.source, model: entry.model),
                                onDayHover: { dayIndex in
                                    if let dayIndex {
                                        sparkDay = (source: entry.source, model: entry.model, dayIndex: dayIndex)
                                    } else if sparkDay?.source == entry.source,
                                              sparkDay?.model == entry.model {
                                        sparkDay = nil
                                    }
                                },
                                highlightOverride: previewSparkDay?.source == entry.source
                                    && previewSparkDay?.model == entry.model
                                    ? previewSparkDay?.dayIndex : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .help("查看该模型明细与 API 等价走势（7|30|90 天可切）")
                        .onHover { hovering in
                            if hovering {
                                hoverEntry = entry
                            } else if hoverEntry == entry {
                                hoverEntry = nil
                            }
                        }
                    }
                    modelHoverCaption
                }

                Text("点击模型看明细；悬停查近 30 天用量。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("用量按所选范围排序；等价按近 30 天、近 7 天按各自窗口排序。小柱图为近 30 天逐日用量。没有对应窗口明细的行排在末尾，CSV 缺少的数值留空。模型榜保留采集来源；Cursor 只有订阅周期聚合，不混入模型榜。")
                if let coverageNote {
                    Text(coverageNote)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }

                Divider()
                HStack(spacing: 6) {
                    Text("Skills 榜").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(range.scopeTitle) · 只认明确调用证据")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    // 筛选激活时给一颗可点的清除胶囊(与徽标同色系)
                    if let filter = activeSkillSourceFilter {
                        Button {
                            skillSourceFilter = nil
                        } label: {
                            Text("\(filter.overviewName) ×")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(filter.overviewColor)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(filter.overviewColor.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("清除来源筛选（当前只看 \(filter.overviewName) 的 Skill 调用）")
                        .accessibilityLabel("清除 Skill 来源筛选")
                    }
                    // 导出完整 Skills 榜（不只前 5）为 CSV
                    Button {
                        exportSkillsCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(skillRankings.entries.isEmpty)
                    .help("导出 Skills 榜 CSV（完整榜单与近 13 周次数）")
                    .accessibilityLabel("导出 Skills 榜 CSV")
                }
                if skillRankings.entries.isEmpty {
                    empty("Claude / Codex / Copilot 暂无可确认的 Skill 调用")
                } else if visibleSkills.isEmpty {
                    empty("\(activeSkillSourceFilter?.overviewName ?? "") 在该范围内暂无 Skill 调用")
                } else {
                    ForEach(Array(visibleSkills.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        Button {
                            onOpenSkill(entry, activeSkillSourceFilter, skillRankings.enabledSources)
                        } label: {
                            skillRow(
                                entry: entry,
                                highlighted: (hoverSkill ?? previewSkillEntry)?.id == entry.id,
                                weekly: skillWeeklyCounts(name: entry.name),
                                onWeekHover: { weekIndex in
                                    if let weekIndex {
                                        skillSparkWeek = (name: entry.name, weekIndex: weekIndex)
                                    } else if skillSparkWeek?.name == entry.name {
                                        skillSparkWeek = nil
                                    }
                                },
                                highlightOverride: previewSkillSparkWeek?.name == entry.name
                                    ? previewSkillSparkWeek?.weekIndex : nil,
                                onSourceTap: { source in
                                    skillSourceFilter = skillSourceFilter == source ? nil : source
                                },
                                activeFilter: activeSkillSourceFilter)
                        }
                        .buttonStyle(.plain)
                        .help("查看该 Skill 近 13 周调用走势与来源拆解")
                        .onHover { hovering in
                            if hovering {
                                hoverSkill = entry
                            } else if hoverSkill == entry {
                                hoverSkill = nil
                            }
                        }
                    }
                    skillHoverCaption
                }

                Text("点击来源筛选，点击 Skill 看明细。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("只计工具确认的调用：Claude 统计原生 Skill 工具，Codex 统计实际读取标准 SKILL.md，Copilot 统计 skill.invoked；普通消息提及不计入。点击来源后，次数、近 13 周趋势、详情与导出随筛选变化；再次点击还原。")
                // 导出反馈行:模型榜与 Skills 榜共用,保存面板点完「存储」后可见
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    /// 导出当前榜单顺序下的完整 Skills 榜（不只界面前 5）为 CSV;
    /// 来源拆解与近 13 周次数和榜内悬停/迷你条同一条取数管线
    private func exportSkillsCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出 Skills 榜 CSV"
        panel.nameFieldStringValue = SkillRankingCSVExport.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SkillRankingCSVExport.makeCSV(
                rows: exportSkillRows,
                scopeTitle: exportScopeTitle
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出 Skills 榜 CSV 失败"
            alert.runModal()
        }
    }

    private var exportSkillRows: [SkillRankingCSVExport.Row] {
        // 导出与所见一致:来源筛选时只导该来源的行,口径行注明已筛
        Self.skillExportRows(
            skillRankings.entries, filteredBy: activeSkillSourceFilter,
            weeklyFor: skillWeeklyCounts)
    }

    static func skillExportRows(
        _ entries: [PersonalSkillRankings.Entry],
        filteredBy source: HistorySource?,
        weeklyFor: (String) -> [(weekOf: String, count: Int)]?
    ) -> [SkillRankingCSVExport.Row] {
        skills(entries, filteredBy: source).enumerated().map { index, entry in
            SkillRankingCSVExport.Row(
                rank: index + 1,
                skill: entry.name,
                invocationCount: entry.invocationCount,
                sharePercent: entry.share,
                sourceNote: entry.sources
                    .map { "\($0.source.overviewName) \(Fmt.int($0.invocationCount)) 次" }
                    .joined(separator: "、"),
                weekly: weeklyFor(entry.name))
        }
    }

    /// 导出口径行里的范围说明:来源筛选激活时注明已筛
    private var exportScopeTitle: String {
        if let filter = activeSkillSourceFilter {
            return "\(range.scopeTitle) · 已筛 \(filter.overviewName)"
        }
        return range.scopeTitle
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
    }

    /// 当前悬停(或夹具强制)的行 id:真实悬停优先,夹具覆盖次之
    private var previewId: String? {
        hoverEntry?.id ?? previewRowId
    }

    /// 悬停说明行:常驻一行,未悬停时显示占位提示,版面不跳动
    private var modelHoverCaption: some View {
        Text(currentHoverText)
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentHoverText: String {
        if let previewTextOverride { return previewTextOverride }
        // 迷你柱单日悬停最具体,优先于整行合计
        if let day = sparkDay ?? previewSparkDay,
           let text = Self.sparklineHoverText(
                source: day.source, model: day.model, dayIndex: day.dayIndex,
                models: rankings.models, seriesFor: sparklineValues) {
            return text
        }
        // 夹具强制行优先(渲染无法模拟指针),其次真实悬停行
        if let entry = hoverEntry ?? rankings.models.first(where: { $0.id == previewRowId }) {
            return Self.hoverText(for: entry, state: state)
        }
        // 未悬停:占位提示占住同一行高,悬停时版面不跳;附当前排序档,
        // 切档后说明行自证口径(文案保持单行放得下,长档名也不截断)
        return "悬停看近 7/30 天 Token、API 等价与活跃天数 · 当前按\(activeSort.rawValue)排序"
    }

    /// 迷你趋势的近 30 天日序列(升序、含补零天);夹具注入优先,
    /// 真实路径与悬停说明行同一条 summary 管线,断流返回 nil(不画)
    private func sparklineValues(source: HistorySource, model: String) -> [(date: String, tokens: Int)]? {
        if let sparklineFor { return sparklineFor(source, model) }
        guard let summary = CodingModelDetail.summary(
            source: source, model: model,
            liveDayModels: CodingModelDetailView.liveDayModels(source, state: state),
            windowDays: 30)
        else { return nil }
        return summary.days.map { (date: $0.date, tokens: $0.tokens) }
    }

    /// 悬停行的取数与拼串:近 30 天断流时引导进详情页
    static func hoverText(
        for entry: PersonalUsageRankings.ModelEntry, state: AppState
    ) -> String {        let live = CodingModelDetailView.liveDayModels(entry.source, state: state)
        guard let month = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: live, windowDays: 30)
        else { return "近 30 天无用量（该行来自更早历史），点进详情页看 90 天" }
        // 周窗可以比月窗更早断流(月内有量但最近 7 天没有),nil 按 0 处理
        let week = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: live, windowDays: 7)
        return hoverPreviewText(week: week, month: month)
    }

    /// 当前悬停(或夹具强制)的 Skill 行;真实悬停优先
    private var previewSkillEntry: PersonalSkillRankings.Entry? {
        if let previewSkillId {
            return visibleSkills.first { $0.id == previewSkillId }
        }
        return nil
    }

    /// 生效中的来源筛选(夹具注入优先);nil = 不过滤
    private var activeSkillSourceFilter: HistorySource? {
        previewSkillSourceFilter ?? skillSourceFilter
    }

    /// 筛选后的 Skills 榜可见行(按当前来源次数排序)
    private var visibleSkills: [PersonalSkillRankings.Entry] {
        Self.skills(skillRankings.entries, filteredBy: activeSkillSourceFilter)
    }

    /// Skills 榜悬停说明行:常驻一行,未悬停时显示占位提示,版面不跳。
    /// 单周悬停最具体,优先于整行来源拆解。
    private var skillHoverCaption: some View {
        Text(currentSkillHoverText)
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentSkillHoverText: String {
        if let week = skillSparkWeek ?? previewSkillSparkWeek,
           let series = skillWeeklyCounts(name: week.name),
           series.indices.contains(week.weekIndex)
        {
            let item = series[week.weekIndex]
            return Self.skillWeekText(weekOf: item.weekOf, count: item.count)
        }
        let activeHoverSkill = visibleSkills.first { $0.id == hoverSkill?.id }
        return activeHoverSkill.map(Self.hoverSkillText)
            ?? previewSkillEntry.map(Self.hoverSkillText)
            ?? "悬停 Skill 行看各来源调用次数"
    }

    private func rankingRow(
        name: String,
        source: HistorySource,
        value: Double?,
        share: Double?,
        showsSource: Bool,
        highlighted: Bool = false,
        sparkline: [(date: String, tokens: Int)]? = nil,
        onDayHover: ((Int?) -> Void)? = nil,
        highlightOverride: Int? = nil
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(source.overviewColor).frame(width: 6, height: 6)
                Text(name).font(Theme.rowTitleFont).lineLimit(1)
                    .help(name)
                if showsSource { sourceBadge(source) }
                Spacer(minLength: 4)
                Text(value.map { activeSort == .usd ? Fmt.usd($0) : Fmt.tokensShort(Int($0)) } ?? "—")
                    .font(Theme.detailFont).foregroundStyle(.secondary)
                    .fixedSize()
                Text(share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(Theme.rowTitleFont).frame(width: 35, alignment: .trailing)
            }
            HStack(spacing: 10) {
                if let share {
                    QuotaBar(progress: share, tint: source.overviewColor)
                } else {
                    Text(activeSort == .usd ? "暂无可计价明细" : "暂无该窗口明细")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                if let sparkline {
                    ModelSparkline(
                        values: sparkline.map(\.tokens), color: source.overviewColor,
                        onDayHover: onDayHover, highlightOverride: highlightOverride)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(ModelPriceCheatSheet.caption(model: name).map { "参考输入 / 输出单价：\($0)" } ?? "暂无参考单价")
        .background {
            // 高亮底色向两侧出血 4pt,行文本与卡内标题/脚注保持对齐
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(highlighted ? 0.05 : 0))
                .padding(.horizontal, -4)
        }
    }

    private func skillRow(
        entry: PersonalSkillRankings.Entry,
        highlighted: Bool = false,
        weekly: [(weekOf: String, count: Int)]? = nil,
        onWeekHover: ((Int?) -> Void)? = nil,
        highlightOverride: Int? = nil,
        onSourceTap: ((HistorySource) -> Void)? = nil,
        activeFilter: HistorySource? = nil
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                ForEach(Array(entry.sources.prefix(2))) { sourceCount in
                    // 徽标可点:只看该来源的 Skill 调用(再点/点胶囊还原)。
                    // 行本身是 Button(进详情),嵌套 Button 的命中区各自独立。
                    Button {
                        onSourceTap?(sourceCount.source)
                    } label: {
                        sourceBadge(
                            sourceCount.source,
                            active: sourceCount.source == activeFilter)
                    }
                    .buttonStyle(.plain)
                    .help("只看 \(sourceCount.source.overviewName) 的 Skill 调用")
            }
                if entry.sources.count > 2 {
                    Text("+\(entry.sources.count - 2)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
            }
                Spacer(minLength: 4)
                Text("\(Fmt.int(entry.invocationCount))次")
                    .font(Theme.detailFont).foregroundStyle(.secondary).fixedSize()
                Text("\(Int((entry.share * 100).rounded()))%")
                    .font(Theme.rowTitleFont).frame(width: 35, alignment: .trailing)
            }
            HStack(spacing: 10) {
                QuotaBar(progress: entry.share, tint: Theme.brand)
                if let weekly {
                    ModelSparkline(
                        values: weekly.map(\.count), color: Theme.brand,
                        onDayHover: onWeekHover, highlightOverride: highlightOverride)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background {
            // 高亮底色向两侧出血 4pt,行文本与卡内标题/脚注保持对齐
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(highlighted ? 0.05 : 0))
                .padding(.horizontal, -4)
        }
    }

    private func sourceBadge(_ source: HistorySource, active: Bool = false) -> some View {
        Text(source.overviewName)
            .font(.system(size: 10, weight: active ? .semibold : .medium))
            .foregroundStyle(source.overviewColor)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(source.overviewColor.opacity(active ? 0.22 : 0.1), in: Capsule())
    }
}

/// 模型榜行尾的近 30 天逐日迷你柱图:Canvas 直绘(比 Charts 轻,
/// 一屏最多 5 行),底对齐、峰值满高;指针在某根柱上时该柱提亮并
/// 回调日序号,悬停说明行由卡片显示对准日的日期与数值。
private struct ModelSparkline: View {
    let values: [Int]
    let color: Color
    var onDayHover: ((Int?) -> Void)? = nil
    // 渲染夹具:强制提亮某根柱(离屏渲染无法模拟指针)
    var highlightOverride: Int? = nil
    @State private var hoveredIndex: Int?

    var body: some View {
        let active = highlightOverride ?? hoveredIndex
        return Canvas { context, size in
            for (index, rect) in OverviewRankingsCard.sparklineBars(
                values: values, width: size.width, height: size.height)
            .enumerated()
            {
                context.fill(
                    Path(rect),
                    with: .color(color.opacity(active == index ? 1.0 : 0.65)))
            }
        }
        .frame(width: 44, height: 14)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard let onDayHover else { return }
            switch phase {
            case .active(let location):
                let index = OverviewRankingsCard.sparklineIndex(
                    atX: location.x, count: values.count, width: 44)
                hoveredIndex = index
                onDayHover(index)
            case .ended:
                hoveredIndex = nil
                onDayHover(nil)
            }
        }
        .accessibilityLabel("近 30 天日用量迷你趋势")
    }
}

