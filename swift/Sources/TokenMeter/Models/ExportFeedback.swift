import Foundation

/// 导出成功的反馈：只显示文件名（不含路径）与完成时刻。
enum ExportFeedback {
    static func text(fileURL: URL, completedAt: Date = Date()) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return "已导出 \(fileURL.lastPathComponent) · \(time.string(from: completedAt))"
    }
}
