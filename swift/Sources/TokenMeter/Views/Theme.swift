import SwiftUI

// 设计 token：原生 macOS 风格，保留 DeepSeek 品牌色与 Flash/Pro 区分色。
enum Theme {
    static let brand = Color(hex: 0x4D6BFE)       // DeepSeek 品牌蓝
    static let flash = Color(hex: 0x4091FF)        // V4 Flash
    static let pro = Color(hex: 0xDA38F0)          // V4 Pro
    static let hit = Color(hex: 0x4091FF)          // 缓存命中
    static let miss = Color(hex: 0xFF9C2B)         // 缓存未命中
    static let response = Color(hex: 0x8B5CF6)     // 输出
    static let codex = Color(hex: 0x10A37F)        // OpenAI 绿
    static let claude = Color(hex: 0xD97757)       // Anthropic 橙

    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 600
    static let corner: CGFloat = 12
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// 卡片容器：原生材质背景 + 圆角，替代 Tauri 版的玻璃拟态自绘
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }
}
