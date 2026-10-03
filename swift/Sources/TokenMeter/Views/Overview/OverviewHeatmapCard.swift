import SwiftUI
import Charts
import AppKit

// 近 13/26 周用量热力图：周为列、周一到周日为行，颜色越深当日合计越大；
// 可按周翻页回看更早历史（上限为最早数据，颜色分档跨页可比）。
// 「日|周|月」粒度切换：周档把每天的格子折成逐周一块（周合计参与分位分档），
// 看更长跨度的周合计走势；月档按自然月折成逐月一块（1|2 年窗口，月合计
// 分位），一眼回看一年以上。翻页与窗口档各粒度独立成套。
// 纯本机按天历史渲染，悬停查看当日/当周/当月数值。
struct OverviewHeatmapCard: View {
    // 热力图窗口档位:13 周为默认档;26 周档格宽收窄到 11pt 以容纳双倍列数
    enum Span: Int, CaseIterable {
        case quarter = 13
        case half = 26

        var title: String { "\(rawValue)周" }
    }

    // 月视图窗口档位。标签用「1年|2年」而非「12月|24月」,避免与月份名混淆。
    enum MonthSpan: Int, CaseIterable {
        case year = 12
        case twoYears = 24

        var title: String { self == .year ? "1年" : "2年" }
    }

    // 粒度:日 = 日历格;周 = 每周折成一块的周合计条;月 = 每个自然月
    // 折成一块的月合计条(1|2 年窗口,回看一年以上)
    enum Granularity: String, CaseIterable {
        case day = "日"
        case week = "周"
        case month = "月"
    }

    let history: [HistoryStore.DayPoint]
    let participants: Set<HistorySource>
    @State private var span: Span
    @State private var monthSpan: MonthSpan
    @State private var granularity: Granularity
    @State private var hoverWeekday: String?
    // 按周/按月翻页:0 = 最近(终点今天),k = 整体前移 k 周/月;上限由最早数据决定
    @State private var weekOffset: Int
    @State private var monthOffset: Int
    // 导出完成后的行内反馈(「已导出 <文件名> · 时刻」);渲染夹具注入固定文案
    @State private var exportStatus: String?
    private let previewExportStatus: String?

    init(
        history: [HistoryStore.DayPoint],
        participants: Set<HistorySource>,
        initialSpan: Span = .quarter,
        initialGranularity: Granularity = .day,
        initialWeekOffset: Int = 0,
        initialMonthSpan: MonthSpan = .year,
        initialMonthOffset: Int = 0,
        previewExportStatus: String? = nil
    ) {
        self.history = history
        self.participants = participants
        _span = State(initialValue: initialSpan)
        _monthSpan = State(initialValue: initialMonthSpan)
        _granularity = State(initialValue: initialGranularity)
        _weekOffset = State(initialValue: initialWeekOffset)
        _monthOffset = State(initialValue: initialMonthOffset)
        _exportStatus = State(initialValue: previewExportStatus)
        self.previewExportStatus = previewExportStatus
    }

    // 索引 = UsageHeatmap.DayCell.level(0...4)
    private static let levelFills: [Color] = [
        Color.primary.opacity(0.06),
        Theme.brand.opacity(0.25),
        Theme.brand.opacity(0.45),
        Theme.brand.opacity(0.65),
        Theme.brand,
    ]
    private static let quarterCellWidth: CGFloat = 13
    private static let halfCellWidth: CGFloat = 11
    private static let cellHeight: CGFloat = 11
    private var cellWidth: CGFloat {
        span == .half ? Self.halfCellWidth : Self.quarterCellWidth
    }

    var body: some View {
        let isMonth = granularity == .month
        let columns = isMonth ? [] : UsageHeatmap.window(
            history, participants: participants,
            windowWeeks: span.rawValue, weekOffset: weekOffset)
        let streak = UsageHeatmap.currentStreak(history, participants: participants)
        let monthRange = isMonth ? UsageHeatmap.monthWindow(
            today: Date(), monthCount: monthSpan.rawValue, monthOffset: monthOffset) : nil
        // 月视图分位只看月合计,金额在确认有用量后再按月窗口逐日重算
        let monthCellsBase = isMonth ? UsageHeatmap.monthlyCells(
            history, participants: participants,
            monthCount: monthSpan.rawValue, monthOffset: monthOffset) : []
        let hasUsage = isMonth
            ? monthCellsBase.contains { $0.level > 0 }
            : columns.flatMap(\.cells).contains { $0.level > 0 }
        let monthApiValues: [String: Double]
        if isMonth, hasUsage, let range = monthRange {
            monthApiValues = UsageHeatmap.dailyAPIValues(
                participants: participants, dateRange: range)
        } else {
            monthApiValues = [:]
        }
        let monthCells = isMonth ? UsageHeatmap.monthlyCells(
            history, participants: participants, apiValues: monthApiValues,
            monthCount: monthSpan.rawValue, monthOffset: monthOffset) : []
        // 悬停 tooltip 的当日金额：同价格口径逐日重算，只在有用量时算
        let apiValues = hasUsage && !isMonth
            ? UsageHeatmap.dailyAPIValues(
                participants: participants,
                windowWeeks: span.rawValue, weekOffset: weekOffset)
            : [:]
        // 单日悬停的「该周几日均」段：与周内节律同一窗口口径（日/周档
        // 逐格共用的分母），预计算一次供全部格子取用
        let weekdayAverages: [Int: Int] = hasUsage && !isMonth
            ? Dictionary(uniqueKeysWithValues: rhythmStats.map { ($0.weekday, $0.average) })
            : [:]
        let maxOffset = isMonth
            ? UsageHeatmap.maxMonthOffset(history, participants: participants)
            : UsageHeatmap.maxWeekOffset(history, participants: participants)
        let rangeText: String
        if isMonth, let range = monthRange {
            rangeText = "\(Fmt.mmdd(range.start)) – \(Fmt.mmdd(range.end))"
        } else {
            rangeText = Self.weekRangeText(columns)
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("用量热力图", systemImage: "square.grid.3x3")
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    pageNavigator(
                        range: rangeText,
                        offset: isMonth ? $monthOffset : $weekOffset,
                        maxOffset: maxOffset,
                        unit: isMonth ? "1 个月" : "\(span.rawValue) 周")
                        .fixedSize(horizontal: true, vertical: false)
                    // 导出当前窗口热力图数据（粒度/窗口/翻页与界面一致）为 CSV
                    Button {
                        exportHeatmapCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasUsage)
                    .help("导出当前窗口 CSV（日/周/月粒度跟随当前选择）")
                    .accessibilityLabel("导出热力图 CSV")
                }
                HStack(spacing: 8) {
                    Picker("粒度", selection: $granularity) {
                        ForEach(Granularity.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("粒度")
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 90)
                    Spacer(minLength: 8)
                    if isMonth {
                        Picker("热力图窗口", selection: $monthSpan) {
                            ForEach(OverviewHeatmapCard.MonthSpan.allCases, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("热力图窗口")
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 64)
                    } else {
                        Picker("热力图窗口", selection: $span) {
                            ForEach(OverviewHeatmapCard.Span.allCases, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("热力图窗口")
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 104)
                    }
                }
                if !hasUsage {
                    Text(isMonth
                        ? "近 \(monthSpan.rawValue) 个月暂无 Coding 用量记录"
                        : "近 \(span.rawValue) 周暂无 Coding 用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    if isMonth {
                        monthStrip(monthCells)
                    } else if granularity == .week {
                        weekStrip(UsageHeatmap.weeklyCells(from: columns, apiValues: apiValues))
                    } else {
                        grid(columns, apiValues: apiValues, weekdayAverages: weekdayAverages)
                    }
                    rhythmChart
                    HStack(spacing: 4) {
                        Text("少")
                            .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        ForEach(1...4, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Self.levelFills[level])
                                .frame(width: 7, height: 7)
                        }
                        Text("多")
                            .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        if (isMonth ? monthOffset : weekOffset) == 0, streak >= 2 {
                            Text("· 当前连续 \(streak) 天")
                                .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(footnoteText)
                        .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                    ExportFeedbackLine(status: exportStatus)
                }
            }
        }
    }

    // 导出热力图当前窗口为 CSV：行与界面所见同窗口同口径（粒度/窗口/
    // 翻页跟随当前选择），日档逐日、周档逐周、月档逐月；金额与悬停同
    // 管线重算，无金额留空。保存面板流程与模型榜导出同款。
    private func exportHeatmapCSV() {
        let granularity: HeatmapCSVExport.Granularity
        let rows: [HeatmapCSVExport.Row]
        let windowText: String
        switch self.granularity {
        case .month:
            granularity = .month
            let range = UsageHeatmap.monthWindow(
                today: Date(), monthCount: monthSpan.rawValue, monthOffset: monthOffset)
            let api = UsageHeatmap.dailyAPIValues(
                participants: participants, dateRange: range)
            rows = UsageHeatmap.monthlyCells(
                history, participants: participants, apiValues: api,
                monthCount: monthSpan.rawValue, monthOffset: monthOffset
            ).map {
                HeatmapCSVExport.Row(
                    bucket: $0.monthKey, weekday: nil,
                    tokens: $0.total, usd: $0.usd > 0 ? $0.usd : nil)
            }
            windowText = "\(DateUtil.key(range.start)) 至 \(DateUtil.key(range.end))"
        case .week, .day:
            granularity = self.granularity == .week ? .week : .day
            let columns = UsageHeatmap.window(
                history, participants: participants,
                windowWeeks: span.rawValue, weekOffset: weekOffset)
            let api = UsageHeatmap.dailyAPIValues(
                participants: participants,
                windowWeeks: span.rawValue, weekOffset: weekOffset)
            if self.granularity == .week {
                rows = UsageHeatmap.weeklyCells(from: columns, apiValues: api).map {
                    HeatmapCSVExport.Row(
                        bucket: $0.weekOf, weekday: nil,
                        tokens: $0.total, usd: $0.usd > 0 ? $0.usd : nil)
                }
            } else {
                rows = columns.flatMap(\.cells).map {
                    HeatmapCSVExport.Row(
                        bucket: $0.date, weekday: $0.weekday,
                        tokens: $0.total, usd: api[$0.date].flatMap { $0 > 0 ? $0 : nil })
                }
            }
            if let first = columns.first?.cells.first?.date,
               let last = columns.last?.cells.last?.date
            {
                windowText = "\(first) 至 \(last)"
            } else {
                windowText = ""
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出热力图 CSV"
        panel.nameFieldStringValue = HeatmapCSVExport.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HeatmapCSVExport.makeCSV(
                rows: rows, granularity: granularity, windowText: windowText
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出热力图 CSV 失败"
            alert.runModal()
        }
    }

    private static func weekRangeText(_ columns: [UsageHeatmap.WeekColumn]) -> String {
        guard let first = columns.first?.cells.first?.date,
              let last = columns.last?.cells.last?.date else { return "" }
        return "\(Fmt.mmdd(first)) – \(Fmt.mmdd(last))"
    }

    // 按周/按月翻页:左箭头看更早,右箭头回来;中间是当前可见范围,翻页后点击
    // 范围文本可直接回到最近(翻得深时不用一格一格点回来)。
    private func pageNavigator(
        range: String,
        offset: Binding<Int>,
        maxOffset: Int,
        unit: String
    ) -> some View {
        return HStack(spacing: 2) {
            Button {
                offset.wrappedValue = min(offset.wrappedValue + 1, max(1, maxOffset))
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(offset.wrappedValue >= maxOffset)
            .accessibilityLabel("更早 \(unit)")
            Group {
                if offset.wrappedValue > 0 {
                    Button(range) { offset.wrappedValue = 0 }
                        .foregroundStyle(.tertiary)
                        .help("回到最近")
                } else {
                    Text(range).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .frame(minWidth: 74)
            .lineLimit(1)
            Group {
                if offset.wrappedValue > 0 {
                    Button {
                        offset.wrappedValue = max(offset.wrappedValue - 1, 0)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更近 \(unit)")
                } else {
                    // 最近一页时右箭头淡出但占位,导航簇宽度不跳动
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.15))
                }
            }
            .disabled(offset.wrappedValue == 0)
        }
    }

    private var footnoteText: String {
        if granularity == .month {
            return monthOffset == 0
                ? "近 \(monthSpan.rawValue) 个月 · 月合计 · 悬停查值 · 描边为本月（进行中）"
                : "月合计 · 悬停查值"
        }
        if granularity == .week {
            return weekOffset == 0
                ? "近 \(span.rawValue) 周 · 周合计 · 悬停查值 · 描边为本周"
                : "周合计 · 悬停查值"
        }
        return weekOffset == 0
            ? "近 \(span.rawValue) 周 · 悬停查值 · 描边为今天"
            : "悬停查值"
    }

    // 月视图:每个自然月折成一块纵向长条,高度与日历格的整列一致(切换不跳动);
    // 颜色按月合计的分位分档。1 年档每月都标月份;2 年档条窄,只标 1 月与
    // 7 月防挤,年份靠悬停文案消歧
    private func monthStrip(_ cells: [UsageHeatmap.MonthCell]) -> some View {
        let currentMonth = String(DateUtil.today().prefix(7))
        // 当月已过的天数（含今天），悬停文案里折日均用
        let currentDay = Calendar.current.component(.day, from: Date())
        return HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: 12, height: 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: monthGap) {
                    ForEach(cells, id: \.monthKey) { cell in
                        let visible = monthSpan == .year || cell.month == 1 || cell.month == 7
                        Text(visible ? "\(cell.month)月" : " ")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: monthBarWidth, height: 10, alignment: .leading)
                    }
                }
                HStack(spacing: monthGap) {
                    ForEach(cells, id: \.monthKey) { cell in
                        let isCurrent = monthOffset == 0 && cell.monthKey == currentMonth
                        // 悬停/无障碍文案一次算好两处复用;上月对照按参与来源
                        // 从同一份按天历史取(上月早于留存起点时自然无对照段)
                        let help = UsageHeatmap.monthHelpText(
                            monthKey: cell.monthKey, total: cell.total,
                            apiValue: cell.usd, inProgress: isCurrent,
                            elapsedDays: isCurrent ? currentDay : nil,
                            previousMonth: UsageHeatmap.previousMonthSummary(
                                monthKey: cell.monthKey, days: history,
                                participants: participants))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.levelFills[cell.level])
                            .overlay {
                                if isCurrent {
                                    // 虚线描边 = 月份进行中(统计至今天),
                                    // 与图表悬停参考线同款虚线语汇;完整月无描边
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(
                                            Color.primary.opacity(0.55),
                                            style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                }
                            }
                            .help(help)
                            .accessibilityLabel(help)
                            .frame(width: monthBarWidth, height: 89)
                    }
                }
            }
        }
    }

    private var monthGap: CGFloat { monthSpan == .twoYears ? 2 : 3 }
    private var monthBarWidth: CGFloat { monthSpan == .twoYears ? 11 : 24 }

    // 周视图:每周折成一块纵向长条,高度与日历格的整列一致(切换不跳动);
    // 颜色按周合计的分位分档,月份标签与日视图同一列对齐
    private func weekStrip(_ cells: [UsageHeatmap.WeekCell]) -> some View {
        let thisWeek = UsageHeatmap.mondayKey(of: Date(), calendar: .current)
        return HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: 12, height: 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(cells, id: \.weekOf) { cell in
                        Text(cell.monthLabel ?? " ")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: cellWidth, height: 10, alignment: .leading)
                    }
                }
                HStack(spacing: 2) {
                    ForEach(cells, id: \.weekOf) { cell in
                        let isCurrent = weekOffset == 0 && cell.weekOf == thisWeek
                        // 本周已过的天数（周一为界，含今天）；进行中的周
                        // 折日均与上周比，避免「周还没过完」误读成骤降
                        let elapsedDays: Int? = {
                            guard isCurrent,
                                  let monday = DateUtil.date(from: cell.weekOf)
                            else { return nil }
                            let diff = Calendar.current.dateComponents(
                                [.day],
                                from: Calendar.current.startOfDay(for: monday),
                                to: Calendar.current.startOfDay(for: Date())).day ?? 0
                            return max(1, diff + 1)
                        }()
                        // 悬停/无障碍文案一次算好两处复用;上周对照按参与
                        // 来源从同一份按天历史取(早于留存起点时无对照段)
                        let help = UsageHeatmap.weekHelpText(
                            weekOf: cell.weekOf, total: cell.total,
                            apiValue: cell.usd, inProgress: isCurrent,
                            elapsedDays: elapsedDays,
                            previousWeek: UsageHeatmap.previousWeekSummary(
                                weekOf: cell.weekOf, days: history,
                                participants: participants))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.levelFills[cell.level])
                            .overlay {
                                if weekOffset == 0, cell.weekOf == thisWeek {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                                }
                            }
                            .help(help)
                            .accessibilityLabel(help)
                            .frame(width: cellWidth, height: 89)
                    }
                }
            }
        }
    }

    private func grid(
        _ columns: [UsageHeatmap.WeekColumn],
        apiValues: [String: Double],
        weekdayAverages: [Int: Int] = [:]
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            weekdayLabels
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(columns, id: \.weekOf) { column in
                        // fixedSize 必须在 Text 上:先 frame 后 fixedSize 时
                        // 文字仍按 11/13pt 宽度截断,月份标签会碎成残笔
                        Text(column.monthLabel ?? " ")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: cellWidth, height: 10, alignment: .leading)
                    }
                }
                HStack(spacing: 2) {
                    ForEach(columns, id: \.weekOf) { column in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { row in
                                cell(
                                    column, row, apiValues: apiValues,
                                    weekdayAverages: weekdayAverages)
                            }
                        }
                    }
                }
            }
        }
    }

    // 周内节律小柱图:窗口内各星期几的日均,峰值柱实色、其余半透明;
    // 说明行与其他图表同款悬停查值,未悬停时显示峰值日。窗口跟随所选
    // 粒度与翻页(月视图按月窗口取数,休整天同样计入分母)
    private var rhythmChart: some View {
        let stats = rhythmStats
        let peak = stats.map(\.average).max() ?? 0
        let active = stats.first { $0.label == hoverWeekday }
            ?? stats.max { $0.average < $1.average }
            ?? UsageHeatmap.WeekdayStat(weekday: 2, average: 0, days: 0, activeDays: 0)
        return VStack(alignment: .leading, spacing: 2) {
            ChartHoverCaption(
                label: "周内节律 · \(UsageHeatmap.weekdayRhythmLabel(active))",
                total: active.average,
                parts: [])
            Chart {
                ForEach(stats, id: \.weekday) { stat in
                    BarMark(
                        x: .value("星期", stat.label),
                        y: .value("日均", stat.average),
                        width: 10
                    )
                    .cornerRadius(1.5)
                    .foregroundStyle(
                        stat.average == peak && peak > 0
                            ? Theme.brand : Theme.brand.opacity(0.35))
                }
                HoverDateRule(date: hoverWeekday)
            }
            .chartXSelection(value: $hoverWeekday)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 38)
        }
        .accessibilityLabel("周内节律")
    }

    private var rhythmStats: [UsageHeatmap.WeekdayStat] {
        if granularity == .month {
            let range = UsageHeatmap.monthWindow(
                today: Date(), monthCount: monthSpan.rawValue, monthOffset: monthOffset)
            return UsageHeatmap.weekdayAverages(
                history, participants: participants, dateRange: range)
        }
        return UsageHeatmap.weekdayAverages(
            history, participants: participants,
            windowWeeks: span.rawValue, weekOffset: weekOffset)
    }

    // 行标签只标周一与周四，其余留空保持与格子同节拍
    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Color.clear.frame(width: 1, height: 12)
            ForEach(0..<7, id: \.self) { row in
                Group {
                    switch row {
                    case 0: Text("一")
                    case 3: Text("四")
                    default: Text(" ")
                    }
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(width: 12, height: Self.cellHeight, alignment: .trailing)
            }
        }
    }

    // 行号 0...6 对应周一...周日;首尾周不满格时留空占位
    private func cell(
        _ column: UsageHeatmap.WeekColumn,
        _ row: Int,
        apiValues: [String: Double],
        weekdayAverages: [Int: Int] = [:]
    ) -> some View {
        let weekday = row == 6 ? 1 : row + 2
        let match = column.cells.first { $0.weekday == weekday }
        return Group {
            if let match {
                // 悬停/无障碍文案一次算好两处复用;附该周几窗口日均
                let help = UsageHeatmap.cellHelpText(
                    date: match.date, total: match.total,
                    apiValue: apiValues[match.date],
                    weekdayAverage: weekdayAverages[match.weekday]
                        .map { (weekday: match.weekday, average: $0) })
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.levelFills[match.level])
                    .overlay {
                        if match.date == DateUtil.today() {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                        }
                    }
                    .help(help)
                    .accessibilityLabel(help)
            } else {
                Color.clear
            }
        }
        .frame(width: cellWidth, height: Self.cellHeight)
    }
}
