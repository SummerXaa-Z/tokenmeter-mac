import Charts
import SwiftUI

// 订阅回本走势：近 N 个完整周逐周回本倍数折线，1 倍虚线为回本线；
// 纵轴封顶 5 倍防单周尖峰压扁其余周，超出按 5 倍画并在脚注说明。
// 总览 API 等价卡与来源页共用；未悬停时说明行显示最近一个完整周。
struct SubscriptionROITrendChart: View {
    let points: [SubscriptionROICurve.WeekPoint]
    @State private var hoverWeek: String?
    @State private var selectedWeek: String?

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
        let active = Self.selectedPoint(in: drawable, key: hoverWeek ?? selectedWeek)
        return VStack(alignment: .leading, spacing: 2) {
            if let active, let multiple = active.multiple {
                WrappingHStack(spacing: 5) {
                    Text("回本走势 · \(Fmt.mmdd(active.weekOf)) 周")
                        .font(.system(size: 10, weight: .semibold))
                    Text((active.isPartial ? "至少 " : "") + SubscriptionValueSummary.multipleText(multiple))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(multiple >= 1 ? Theme.brand : .orange)
                    Text("\(Fmt.usd(active.apiValueUSD)) / \(Fmt.usd(active.feeUSD))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("回本走势，\(Fmt.ymd(active.weekOf)) 周，\(active.isPartial ? "至少 " : "")\(SubscriptionValueSummary.multipleText(multiple))，API 等价 \(Fmt.usd(active.apiValueUSD))，分摊订阅费 \(Fmt.usd(active.feeUSD))")
            }
            Chart {
                ForEach(drawable) { point in
                    LineMark(
                        x: .value("周", point.weekOf),
                        y: .value("回本倍数", min(point.multiple ?? 0, yCeiling))
                    )
                    .foregroundStyle(Theme.brand.opacity(0.8))
                    .interpolationMethod(.monotone)
                    if point.id == (hoverWeek ?? selectedWeek ?? active?.id) {
                        PointMark(
                            x: .value("周", point.weekOf),
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
            .onChange(of: hoverWeek) { _, key in
                // Swift Charts clears transient selection when a gesture ends.
                // Keep the last real bucket so click/drag selection stays visible.
                if let key, drawable.contains(where: { $0.weekOf == key }) { selectedWeek = key }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { tap in
                                guard let anchor = proxy.plotFrame else { return }
                                let plot = geometry[anchor]
                                guard plot.contains(tap.location),
                                      let key = proxy.value(atX: tap.location.x - plot.minX, as: String.self),
                                      drawable.contains(where: { $0.weekOf == key }) else { return }
                                selectedWeek = key
                                hoverWeek = key
                            }
                        )
                }
            }
            .chartYScale(domain: 0...yCeiling)
            .numericYAxis(desiredCount: 4)
            .dateXAxis(labels: Dictionary(uniqueKeysWithValues: drawable.map { ($0.weekOf, Fmt.mmdd($0.weekOf)) }), desiredCount: 4)
            .overlay(alignment: .topTrailing) {
                Text("1倍")
                    .font(Theme.footnoteFont)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 22)
                    .padding(.top, 1)
            }
            .frame(height: 64)
            Text(capped
                 ? "虚线为回本线（1 倍）；纵轴截至 5 倍，更高的周按 5 倍显示。"
                 : "虚线为 1 倍参考线；缺价周不画未知倍数，部分计价的金额和倍数仅为下限。")
                .font(Theme.footnoteFont).foregroundStyle(.secondary)
        }
    }

    static func selectedPoint(in points: [SubscriptionROICurve.WeekPoint], key: String?) -> SubscriptionROICurve.WeekPoint? {
        points.first { $0.weekOf == key } ?? points.last
    }
}
