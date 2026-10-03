import SwiftUI
import AppKit

// 全来源周期环比：周/月切换，合计行 + 各来源行，数据来自本机按天历史。
// 与 Claude 页「周趋势」同语义（本期截至今天 vs 完整上期），口径为全部 Coding 来源。
struct OverviewCompareCard: View {
    let history: [HistoryStore.DayPoint]
    let participants: Set<HistorySource>
    @State private var period: PeriodCompare.Period = .week
    // 渲染夹具:注入固定的导出反馈文案(保存面板无法离屏模拟)
    var previewExportStatus: String? = nil
    // 导出完成后的行内反馈(「已导出 <文件名> · 时刻」)
    @State private var exportStatus: String?

    var body: some View {
        let compare = PeriodCompare.bySource(
            history, period: period, participants: participants)
        let rows = PeriodCompare.rows(this: compare.this, last: compare.last)
        let thisTotal = compare.this.values.reduce(0, +)
        let lastTotal = compare.last.values.reduce(0, +)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(period.title)（全部 Coding 来源）", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("周期", selection: $period) {
                        Text("周").tag(PeriodCompare.Period.week)
                        Text("近7天").tag(PeriodCompare.Period.rolling7)
                        Text("月").tag(PeriodCompare.Period.month)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 104)
                    // 导出当前周期的环比表(合计 + 各来源,附口径行)
                    Button {
                        exportCSV(compare: compare)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(rows.isEmpty)
                    .help("导出当前周期环比 CSV（合计与各来源本期/上期/环比）")
                    .accessibilityLabel("导出环比 CSV")
                }
                if rows.isEmpty {
                    Text("本周期与上一周期暂无 Coding 用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    compareRow(
                        name: "合计", color: nil,
                        this: thisTotal, last: lastTotal, emphasized: true)
                    ForEach(rows, id: \.source) { row in
                        compareRow(
                            name: row.source.overviewName,
                            color: row.source.overviewColor,
                            this: row.this, last: row.last, emphasized: false)
                    }
                    Text("\(period.footnote)；DeepSeek 平台账户不计入。")
                        .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                    // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                    ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
                }
            }
        }
    }

    /// 导出当前周期环比 CSV：合计 + 各来源（本期/上期/环比），行序与卡片
    /// 一致。保存面板流程与热力图/趋势导出同款，写盘失败弹系统错误框。
    private func exportCSV(
        compare: (this: [HistorySource: Int], last: [HistorySource: Int])
    ) {
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出环比 CSV",
            filename: PeriodCompareCSVExport.suggestedFilename(period: period)
        ) {
            PeriodCompareCSVExport.makeCSV(
                period: period, this: compare.this, last: compare.last
            )
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }

    // 来源名列定宽让各行对齐；本期值粗体、上期值灰、行尾环比徽标
    private func compareRow(
        name: String, color: Color?, this: Int, last: Int, emphasized: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .frame(width: emphasized ? 70 : 64, alignment: .leading)
            Text(Fmt.tokensShort(this))
                .font(.system(
                    size: 11, weight: emphasized ? .semibold : .medium, design: .rounded))
                .frame(width: emphasized ? 58 : 56, alignment: .leading)
            Text("上期 \(Fmt.tokensShort(last))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            ChangeBadge(change: PeriodCompare.change(this: this, last: last))
        }
    }
}
