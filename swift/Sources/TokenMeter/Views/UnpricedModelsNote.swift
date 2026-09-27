import SwiftUI

// API 等价卡的「缺价模型自报家门」行：橙色提示文案 + 一键复制完整清单。
// 卡内只列前三个名字保持版面安静，完整名单靠复制带走，方便在反馈时
// 原样报出缺价模型（维护者据此收录进价格目录，见 make price-check）。
struct UnpricedModelsNote: View {
    let names: [String]
    @State private var copied = false

    var body: some View {
        if let caption = Self.caption(names) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(caption)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(copied ? "已复制" : "复制") { copyToPasteboard() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied ? Theme.hit : Theme.brand)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(caption)，按钮复制全部模型名")
        }
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.copyText(names), forType: .string)
        copied = true
        // 短暂显示「已复制」后复位；用户再次点击仍可重复复制
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    // 卡内文案：最多列 3 个模型名，其余收进「等」；没有缺价时返回 nil 不渲染
    static func caption(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let listed = names.prefix(3).joined(separator: "、")
        let suffix = names.count > 3 ? " 等" : ""
        return "另有 \(names.count) 个模型缺少参考价，未计入金额：\(listed)\(suffix)"
    }

    // 剪贴板内容：每行一个模型名，粘进反馈或 issue 时保持原样
    static func copyText(_ names: [String]) -> String {
        names.joined(separator: "\n")
    }
}
