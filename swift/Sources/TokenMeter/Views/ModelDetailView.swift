import SwiftUI
import Charts

// 模型详情页：单模型的 token 明细 + 7 天趋势
struct ModelDetailView: View {
    @EnvironmentObject var state: AppState
    let modelKey: String
    var onBack: () -> Void

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
                        stat("总 Tokens", Fmt.tokensShort(m.totalTokens))
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
                        Text("近 7 天 Tokens").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Chart(points) { p in
                            BarMark(x: .value("日期", p.date), y: .value("Tokens", p.tokens))
                                .foregroundStyle(accent)
                                .cornerRadius(3)
                        }
                        .tokenYAxis()
                        .frame(height: 160)
                    }
                }
            } else {
                Spacer()
                Text("暂无数据").foregroundStyle(.secondary)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Image(systemName: isFlash ? "bolt.fill" : "brain")
                .foregroundStyle(accent)
            Text(isFlash ? "V4 Flash" : "V4 Pro")
                .font(.system(size: 15, weight: .bold))
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
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
}
