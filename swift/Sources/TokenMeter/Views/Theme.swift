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
    func tokenYAxis() -> some View {
        chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let n = v.as(Int.self) { Text(Fmt.tokensShort(n)) }
                    else if let d = v.as(Double.self) { Text(Fmt.tokensShort(Int(d))) }
                }
            }
        }
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
