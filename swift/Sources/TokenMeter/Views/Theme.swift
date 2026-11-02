import SwiftUI

// 设计 token：原生 macOS 风格，保留 DeepSeek 品牌色与 Flash/Pro 区分色。
enum Theme {
    static let brand = Color(hex: 0x4D6BFE)       // DeepSeek 品牌蓝
    static let flash = Color(hex: 0x4091FF)        // V4 Flash
    static let pro = Color(hex: 0xDA38F0)          // V4 Pro
    static let hit = Color(hex: 0x4091FF)          // 缓存命中
    static let miss = Color(hex: 0xFF9C2B)         // 缓存未命中
    static let input = Color(hex: 0x34C759)        // 新输入（未命中缓存的输入）
    static let response = Color(hex: 0x8B5CF6)     // 输出
    static let codex = Color(hex: 0x10A37F)        // OpenAI 绿
    static let claude = Color(hex: 0xD97757)       // Anthropic 橙
    static let kimi = Color(hex: 0x7C3AED)         // Kimi 紫
    static let cursor = Color(hex: 0x7C8AFF)       // Cursor 紫蓝
    static let opencode = Color(hex: 0xF59E0B)     // OpenCode 琥珀
    static let gemini = Color(hex: 0x4285F4)       // Gemini 蓝
    static let copilot = Color(hex: 0x6E40C9)      // GitHub Copilot 紫
    static let qwen = Color(hex: 0x615CED)          // Qwen 蓝紫
    static let zhipu = Color(hex: 0x3859FF)         // 智谱品牌蓝

    static let panelWidth: CGFloat = 420
    static let panelHeight: CGFloat = 600
    static let corner: CGFloat = 12

    // 字号刻度（420pt 弹窗内的完整层级，新代码一律取这些档位，不再引入新的魔法数字）：
    //   26 hero 数字 · 15 页标题 · 13 设置段标题 · 12 卡片/连接标题 ·
    //   11 行标题(semibold)与正文细节(regular) · 10 脚注、徽章与 tertiary 说明。
    // 副标题/状态行/小数值走 11；只有胶囊徽章和 tertiary 灰字才允许 10，
    // 更小会在暗色卡底上糊掉。
    static let heroFont = Font.system(size: 26, weight: .bold, design: .rounded)
    static let pageTitleFont = Font.system(size: 15, weight: .bold)
    static let sectionTitleFont = Font.system(size: 13, weight: .bold)
    static let cardTitleFont = Font.system(size: 12, weight: .semibold)
    static let rowTitleFont = Font.system(size: 11, weight: .semibold)
    static let detailFont = Font.system(size: 11)
    static let footnoteFont = Font.system(size: 10)
    static let badgeFont = Font.system(size: 10, weight: .semibold)
    static let chartAxisFont = Font.system(size: 10)
    static let minimumControlSize: CGFloat = 28
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

import Charts

// 所有 token 数量图表共用的 Y 轴：tokensShort 格式（30M / 1.2B），
// 替代 Swift Charts 默认的刻度文案。Charts 给出的刻度值是 Double，
// 必须走 Double 分支，否则自定义标签落空、回退到系统默认格式。
extension View {
    func tokenYAxis(desiredCount: Int = 5) -> some View {
        chartYAxis {
            AxisMarks(values: .automatic(desiredCount: desiredCount)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let n = v.as(Int.self) {
                        Text(Fmt.tokensShort(n))
                            .font(Theme.chartAxisFont).foregroundStyle(Color.secondary)
                    } else if let d = v.as(Double.self) {
                        Text(Fmt.tokensShort(Int(d)))
                            .font(Theme.chartAxisFont).foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    // Plain numerical axes keep their original units (count, USD, multiple).
    // Significant digits preserve small fractional amounts without forcing
    // currency rounding or abbreviating values as Token units.
    func numericYAxis(desiredCount: Int = 5) -> some View {
        chartYAxis {
            AxisMarks(values: .automatic(desiredCount: desiredCount)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number, format: .number.precision(.significantDigits(1...15)))
                            .font(Theme.chartAxisFont).foregroundStyle(Color.secondary)
                    } else if let number = value.as(Int.self) {
                        Text(number, format: .number)
                            .font(Theme.chartAxisFont).foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    // Data identity stays a complete date key; only its visible label is abbreviated.
    func dateXAxis(labels: [String: String] = [:], desiredCount: Int = 6) -> some View {
        let keys = ChartAxisTicks.sampledKeys(Array(labels.keys), maximumCount: desiredCount)
        let visibleKeys = Set(keys)
        return chartXAxis {
            // Keep a single concrete AxisMarks node and guard label emission as
            // well as tick selection; never label all categorical buckets.
            AxisMarks(values: keys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), visibleKeys.contains(key) {
                        Text(labels[key] ?? Fmt.mmdd(key))
                            .font(Theme.chartAxisFont)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }
}

enum ChartAxisTicks {
    static func sampledKeys(_ keys: [String], maximumCount: Int = 6) -> [String] {
        let keys = Array(Set(keys)).sorted()
        guard maximumCount > 0 else { return [] }
        guard keys.count > maximumCount else { return keys }
        guard maximumCount > 1 else { return [keys.last!] }
        return (0..<maximumCount).map { index in
            keys[Int((Double(index) * Double(keys.count - 1) / Double(maximumCount - 1)).rounded())]
        }
    }
}

// Flow layout for legends and captions: all labels remain visible in a narrow panel.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arranged(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arranged(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 proposal: ProposedViewSize(frame.size))
        }
    }

    private func arranged(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(proposal.width ?? .infinity, 1)
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let itemWidth = min(ideal.width, width)
            let size = view.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            if x > 0, x + itemWidth > width {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
            usedWidth = max(usedWidth, x + itemWidth)
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        // Keep the measured wrapping width for placement; returning only the
        // widest row could make placement wrap again into a taller layout.
        let measuredWidth = proposal.width.flatMap { $0.isFinite ? max($0, 1) : nil } ?? usedWidth
        return (CGSize(width: measuredWidth, height: y + rowHeight), frames)
    }
}

// 卡片容器：原生材质背景 + 圆角，替代 Tauri 版的玻璃拟态自绘。
// 描边用 primary 而非 .white，亮色模式下才有可见的发丝线。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

// 总览用轻分隔线组织连续读数，避免每个指标都套一层灰色卡片。
struct OverviewSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Divider().opacity(0.45)
            }
    }
}

// 全 app 统一的细进度条（4pt 胶囊）：用量占比、配额剩余、覆盖率都用它，
// 不再各页混用 GeometryReader 手绘与内联 ProgressView。
struct QuotaBar: View {
    let progress: Double   // 任意比例值，内部收敛到 0...1
    var tint: Color = Theme.brand
    // 可选参照刻度（0...1）：额度条上标"匀速消耗此刻应剩多少"，
    // 填充短于刻度即用得比匀速快
    var marker: Double? = nil

    var body: some View {
        let fraction = min(max(progress, 0), 1)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                if fraction > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(4, fraction * geo.size.width), height: 4)
                }
                if let marker {
                    let x = min(max(marker, 0), 1) * geo.size.width
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: 8)
                        .offset(x: min(max(x - 0.75, 0), geo.size.width - 1.5))
                }
            }
        }
        .frame(height: marker == nil ? 4 : 8)
    }
}

// 菜单栏面板是纯鼠标场景：可点的行/卡需要悬停反馈，否则"能点"无从感知。
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(hovering ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
