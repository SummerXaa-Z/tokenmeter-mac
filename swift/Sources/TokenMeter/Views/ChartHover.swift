import SwiftUI
import Charts

// 图表悬停查值的共用原语：说明行 + 虚线参考线。
// 说明行固定高度、放在图表上方：未悬停显示最新一桶，悬停时切换到指针下的桶，版面不跳动。

/// 图表悬停说明行：桶标签 + 合计 + 主要分量（色点 + 数值）。
/// parts 传入未排序未过滤，内部按值取前几个非零分量。
struct ChartHoverCaption: View {
    let label: String
    let total: Int
    let parts: [(name: String, value: Int, color: Color)]

    var body: some View {
        let top = ChartHover.topParts(parts)
        return HStack(spacing: 6) {
            Text(label)
                .font(Theme.rowTitleFont).foregroundStyle(.secondary)
            Text(Fmt.tokensShort(total))
                .font(Theme.rowTitleFont)
            ForEach(Array(top.visible.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 3) {
                    Circle().fill(part.color).frame(width: 4, height: 4)
                    Text("\(part.name) \(Fmt.tokensShort(part.value))")
                }
                .font(Theme.detailFont).foregroundStyle(.secondary)
            }
            if top.overflowCount > 0 {
                Text("+\(top.overflowCount) 项")
                    .font(Theme.detailFont).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(height: 14, alignment: .leading)
    }
}

enum ChartHover {
    /// 桶内分量按值降序、剔除零值后只留前 limit 个；overflowCount 是其余非零分量数。
    static func topParts(
        _ parts: [(name: String, value: Int, color: Color)],
        limit: Int = 3
    ) -> (visible: [(name: String, value: Int, color: Color)], overflowCount: Int) {
        let nonzero = parts.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let visible = Array(nonzero.prefix(limit))
        return (visible, nonzero.count - visible.count)
    }

    /// 通用说明行装配：hover 指向的桶，缺省回落到最后一桶（buckets 按时间升序）。
    @ViewBuilder
    static func caption(
        hover: String?,
        buckets: [(label: String, total: Int, parts: [(name: String, value: Int, color: Color)])]
    ) -> some View {
        if let active = buckets.first(where: { $0.label == hover }) ?? buckets.last {
            ChartHoverCaption(label: active.label, total: active.total, parts: active.parts)
        }
    }
}

// Chart 内容里的悬停虚线参考线。x 值类型必须与该图表 BarMark 的 x 完全一致，
// 两种形态对应全库仅有的两类 x 轴：分类标签（日期）与数值（小时）。
private struct HoverRule<X: Plottable>: ChartContent {
    let name: String
    let x: X?

    var body: some ChartContent {
        if let x {
            RuleMark(x: .value(name, x))
                .foregroundStyle(Color.primary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

struct HoverDateRule: ChartContent {
    let date: String?
    var body: some ChartContent { HoverRule(name: "日期", x: date) }
}

struct HoverHourRule: ChartContent {
    let hour: Int?
    var body: some ChartContent { HoverRule(name: "小时", x: hour) }
}
