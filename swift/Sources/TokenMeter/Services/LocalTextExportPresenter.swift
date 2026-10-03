import AppKit
import UniformTypeIdentifiers

/// 交互式本地文本导出的 IO 壳。CSV 内容、范围和筛选仍由各页面的纯模型决定。
/// 先选择目的文件，再生成内容；取消不读取导出数据，也不写盘。
@MainActor
struct LocalTextExportPresenter {
    struct Request {
        let title: String
        let filename: String
        let contentType: UTType
        let failureTitle: String
    }

    enum Outcome: Equatable {
        case cancelled
        case completed(fileURL: URL, feedback: String)
        case failed(message: String)

        /// 卡片只在成功后替换原来的反馈；取消或失败保留上次成功结果。
        var successFeedback: String? {
            guard case .completed(_, let feedback) = self else { return nil }
            return feedback
        }

        /// 设置页另保留失败的行内说明；取消时不改已有状态。
        var statusText: String? {
            switch self {
            case .cancelled: return nil
            case .completed(_, let feedback): return feedback
            case .failed(let message): return "导出失败：\(message)"
            }
        }
    }

    static let shared = LocalTextExportPresenter(
        selectDestination: { request in
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.title = request.title
            panel.nameFieldStringValue = request.filename
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.allowedContentTypes = [request.contentType]
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        },
        presentError: { error, title in
            let alert = NSAlert(error: error)
            alert.messageText = title
            alert.runModal()
        })

    private let selectDestination: (Request) -> URL?
    private let write: (String, URL) throws -> Void
    private let presentError: (Error, String) -> Void
    private let now: () -> Date

    init(
        selectDestination: @escaping (Request) -> URL?,
        write: @escaping (String, URL) throws -> Void = { text, url in
            try writeUTF8Atomically(text, to: url)
        },
        presentError: @escaping (Error, String) -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.selectDestination = selectDestination
        self.write = write
        self.presentError = presentError
        self.now = now
    }

    func export(
        title: String,
        filename: String,
        contentType: UTType = .commaSeparatedText,
        failureTitle: String? = nil,
        content: () throws -> String
    ) -> Outcome {
        let request = Request(
            title: title, filename: filename, contentType: contentType,
            failureTitle: failureTitle ?? "\(title) 失败")
        guard let url = selectDestination(request) else { return .cancelled }
        do {
            let text = try content()
            try write(text, url)
            return .completed(fileURL: url, feedback: ExportFeedback.text(
                fileURL: url, completedAt: now()))
        } catch {
            presentError(error, request.failureTitle)
            return .failed(message: error.localizedDescription)
        }
    }

    nonisolated static func writeUTF8Atomically(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
