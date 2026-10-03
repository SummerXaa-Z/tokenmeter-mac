import SwiftUI
import Charts
import AppKit

// 模型详情页：单模型的 token 明细 + 7 天趋势
struct ModelDetailView: View {
    @EnvironmentObject var state: AppState
    let modelKey: String
    var onBack: () -> Void
    // 渲染夹具：注入固定的导出反馈文案（离屏渲染无法模拟保存面板）
    var previewExportStatus: String? = nil
    @State private var hoverDate: String?
    // 导出完成后的行内反馈（「已导出 <文件名> · 时刻」）
    @State private var exportStatus: String?

    private var isFlash: Bool { modelKey == "flash" }
    private var accent: Color { isFlash ? Theme.flash : Theme.pro }
    private var model: UsageModelSummary? { state.usage?.model(modelKey) }

    private struct DayPoint: Identifiable {
        let id = UUID()
        let date: String
        let tokens: Int
    }
    private var points: [DayPoint] {
        DateUtil.recentDays(state.usage?.days ?? []).map {
            DayPoint(date: Fmt.mmdd($0.date),
                     tokens: isFlash ? $0.flashTokens : $0.proTokens)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if let m = model {
                Card {
                    HStack(spacing: 16) {
                        stat("总 Token", Fmt.tokensShort(m.totalTokens))
                        stat("请求数", Fmt.int(m.requestCount))
                        stat("消费", Fmt.money(m.cost))
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Token 构成").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        breakdownRow("缓存命中", m.cacheHitTokens, Theme.hit)
                        breakdownRow("缓存未命中", m.cacheMissTokens, Theme.miss)
                        breakdownRow("输出", m.responseTokens, Theme.response)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("近 7 天 Token").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            // 与模型榜/Skill 详情/来源模型详情导出同款入口
                            Button {
                                exportCSV(m)
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("导出近 7 天逐日 Token CSV（附汇总与构成口径行）")
                            .accessibilityLabel("导出模型近 7 天 CSV")
                        }
                        ChartHover.caption(
                            hover: hoverDate,
                            buckets: points.map { ($0.date, $0.tokens, []) }
                        )
                        Chart {
                            ForEach(points) { p in
                                BarMark(x: .value("日期", p.date), y: .value("Tokens", p.tokens))
                                    .foregroundStyle(accent)
                                    .cornerRadius(3)
                            }
                            HoverDateRule(date: hoverDate)
                        }
                        .chartXSelection(value: $hoverDate)
                        .tokenYAxis()
                        .frame(height: 160)
                        // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                        ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
                    }
                }
            } else {
                SourceStateView(message: "暂无数据")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: isFlash ? "bolt.fill" : "brain",
            title: isFlash ? "V4 Flash" : "V4 Pro",
            color: accent,
            onBack: onBack
        )
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdownRow(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(Fmt.int(value)).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// 导出近 7 天逐日 CSV；保存面板流程与其他导出同款，写盘失败弹系统错误框
    private func exportCSV(_ m: UsageModelSummary) {
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出模型近 7 天 CSV",
            filename: DeepSeekModelCSVExport.suggestedFilename(modelKey: modelKey),
            failureTitle: "导出失败"
        ) {
            let rows = DateUtil.recentDays(state.usage?.days ?? []).map {
                DeepSeekModelCSVExport.Row(
                    date: $0.date,
                    tokens: isFlash ? $0.flashTokens : $0.proTokens)
            }
            return DeepSeekModelCSVExport.makeCSV(model: m, rows: rows)
        }
        if let feedback = outcome.successFeedback { exportStatus = feedback }
    }
}
