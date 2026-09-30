import Charts
import SwiftUI

// 订阅回本走势：近 N 个完整周逐周回本倍数折线，1 倍虚线为回本线；
// 纵轴封顶 5 倍防单周尖峰压扁其余周，超出按 5 倍画并在脚注说明。
// 总览 API 等价卡与来源页共用；未悬停时说明行显示最近一个完整周。
struct SubscriptionROITrendChart: View {
    let points: [SubscriptionROICurve.WeekPoint]
    @State private var hoverWeek: String?

    var body: some View {
        let drawable = points.filter { $0.multiple != nil }
        if drawable.isEmpty {
            EmptyView()
        } else {
            chartBody(drawable)
        }
    }

    private func chartBody(
        _ drawable: [SubscriptionROICurve.WeekPoint]
    ) -> some View {
        let maxMultiple = drawable.compactMap(\.multiple).max() ?? 1
        let yCeiling = min(max(1.5, maxMultiple * 1.1), 5)
        let capped = maxMultiple * 1.1 > 5
        let active = drawable.first { $0.id == hoverWeek } ?? drawable.last
        return VStack(alignment: .leading, spacing: 2) {
            if let active, let multiple = active.multiple {
                HStack(spacing: 5) {
                    Text("回本走势 · \(Fmt.mmdd(active.weekOf)) 周")
                        .font(.system(size: 10, weight: .semibold))
                    Text(SubscriptionValueSummary.multipleText(multiple))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(multiple >= 1 ? Theme.brand : .orange)
                    Text("\(Fmt.usd(active.apiValueUSD)) / \(Fmt.usd(active.feeUSD))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            Chart {
                ForEach(drawable) { point in
                    LineMark(
                        x: .value("周", Fmt.mmdd(point.weekOf)),
                        y: .value("回本倍数", min(point.multiple ?? 0, yCeiling))
                    )
                    .foregroundStyle(Theme.brand.opacity(0.8))
                    .interpolationMethod(.monotone)
                    if point.id == (hoverWeek ?? active?.id) {
                        PointMark(
                            x: .value("周", Fmt.mmdd(point.weekOf)),
                            y: .value("回本倍数", min(point.multiple ?? 0, yCeiling))
                        )
                        .foregroundStyle(Theme.brand)
                        .symbolSize(30)
                    }
                }
                RuleMark(y: .value("回本线", 1))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXSelection(value: $hoverWeek)
            .chartYScale(domain: 0...yCeiling)
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
            .overlay(alignment: .topTrailing) {
                Text("1倍")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 22)
                    .padding(.top, 1)
            }
            .frame(height: 64)
            Text(capped
                 ? "虚线为回本线（1 倍）；纵轴截至 5 倍，更高的周按 5 倍显示。"
                 : "虚线为回本线（1 倍），低于它表示该周按 API 付费更省。")
                .font(Theme.footnoteFont).foregroundStyle(.tertiary)
        }
        .accessibilityLabel("回本走势")
    }
}
