import SwiftUI

// 导出完成后的行内反馈：各导出卡（热力图 / 模型榜 / Skills 榜 / Skill 详情 /
// 两个模型详情页）保存面板点完「存储」后，卡内直接可见写到了哪个文件、
// 什么时候——不用猜面板有没有生效，也不必去翻目标文件夹。
// 式样与设置页推样例反馈（「已推 N 条样例 · 09:41」）同款。

/// 反馈文案（纯函数，可测）：文件名（不含路径）+ 完成时刻。
enum ExportFeedback {
    static func text(fileURL: URL, completedAt: Date = Date()) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return "已导出 \(fileURL.lastPathComponent) · \(time.string(from: completedAt))"
    }
}

/// 反馈行：有文案才显示（版面不预留空位），失败提示由调用方另行弹框。
struct ExportFeedbackLine: View {
    let status: String?

    var body: some View {
        if let status {
            Text(status)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
