import XCTest
import UniformTypeIdentifiers
@testable import TokenMeter

final class LocalTextExportPresenterTests: XCTestCase {
    private enum Failure: LocalizedError {
        case generation, writing

        var errorDescription: String? {
            switch self {
            case .generation: return "无法生成内容"
            case .writing: return "无法写入文件"
            }
        }
    }

    private var destination: URL {
        URL(fileURLWithPath: "/tmp/synthetic-exports/selected-name.csv")
    }

    @MainActor
    func testCancellationDoesNotGenerateContentWritePresentErrorOrReadClock() {
        var events: [String] = []
        let presenter = LocalTextExportPresenter(
            selectDestination: { _ in events.append("select"); return nil },
            write: { _, _ in events.append("write") },
            presentError: { _, _ in events.append("error") },
            now: { events.append("clock"); return Date() })

        let outcome = presenter.export(title: "导出用量 CSV", filename: "usage.csv") {
            events.append("content")
            throw Failure.generation
        }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(events, ["select"])
        XCTAssertNil(outcome.successFeedback)
        XCTAssertNil(outcome.statusText)
    }

    @MainActor
    func testSuccessPassesRequestAndExactContentToChosenFileBeforeFeedback() {
        var events: [String] = []
        let selectedURL = destination
        let completedAt = Calendar.current.date(from: DateComponents(
            year: 2026, month: 10, day: 3, hour: 9, minute: 41))!
        let text = "模型,Token\n合成模型,123\n"
        let presenter = LocalTextExportPresenter(
            selectDestination: { request in
                XCTAssertEqual(request.title, "导出模型榜 CSV")
                XCTAssertEqual(request.filename, "suggested-models.csv")
                XCTAssertEqual(request.contentType, .commaSeparatedText)
                XCTAssertEqual(request.failureTitle, "导出模型榜 CSV 失败")
                events.append("select")
                return selectedURL
            },
            write: { actualText, actualURL in
                XCTAssertEqual(actualText, text)
                XCTAssertEqual(actualURL, selectedURL)
                events.append("write")
            },
            presentError: { _, _ in XCTFail("成功不应弹错误框") },
            now: { events.append("clock"); return completedAt })

        let outcome = presenter.export(
            title: "导出模型榜 CSV", filename: "suggested-models.csv"
        ) {
            events.append("content")
            return text
        }

        let feedback = "已导出 selected-name.csv · 09:41"
        XCTAssertEqual(outcome, .completed(fileURL: selectedURL, feedback: feedback))
        XCTAssertEqual(outcome.successFeedback, feedback)
        XCTAssertEqual(outcome.statusText, feedback)
        XCTAssertEqual(events, ["select", "content", "write", "clock"])
    }

    @MainActor
    func testContentGenerationFailureNeverWritesOrReportsSuccess() {
        var writes = 0
        var errors: [String] = []
        let presenter = LocalTextExportPresenter(
            selectDestination: { _ in self.destination },
            write: { _, _ in writes += 1 },
            presentError: { error, title in
                errors.append("\(title):\(error.localizedDescription)")
            },
            now: { XCTFail("失败不能生成成功时间"); return Date() })

        let outcome = presenter.export(title: "导出趋势 CSV", filename: "trend.csv") {
            throw Failure.generation
        }

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(errors, ["导出趋势 CSV 失败:无法生成内容"])
        XCTAssertEqual(outcome, .failed(message: "无法生成内容"))
        XCTAssertNil(outcome.successFeedback)
        XCTAssertEqual(outcome.statusText, "导出失败：无法生成内容")
    }

    @MainActor
    func testWriteFailureUsesRequestedTextTypeAndFailureTitle() {
        var contentCalls = 0
        var writeCalls = 0
        var errors: [String] = []
        let presenter = LocalTextExportPresenter(
            selectDestination: { request in
                XCTAssertEqual(request.contentType, .plainText)
                XCTAssertEqual(request.filename, "diagnostic.txt")
                return self.destination
            },
            write: { text, _ in
                XCTAssertEqual(text, "合成诊断文本")
                writeCalls += 1
                throw Failure.writing
            },
            presentError: { error, title in
                errors.append("\(title):\(error.localizedDescription)")
            },
            now: { XCTFail("失败不能生成成功时间"); return Date() })

        let outcome = presenter.export(
            title: "导出诊断信息", filename: "diagnostic.txt",
            contentType: .plainText, failureTitle: "导出诊断失败"
        ) {
            contentCalls += 1
            return "合成诊断文本"
        }

        XCTAssertEqual(contentCalls, 1)
        XCTAssertEqual(writeCalls, 1)
        XCTAssertEqual(errors, ["导出诊断失败:无法写入文件"])
        XCTAssertEqual(outcome, .failed(message: "无法写入文件"))
        XCTAssertNil(outcome.successFeedback)
        XCTAssertEqual(outcome.statusText, "导出失败：无法写入文件")
    }

    @MainActor
    func testDefaultWriterAtomicallyReplacesFileWithExactUTF8Bytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TokenMeter-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.csv")
        try Data("old contents".utf8).write(to: url)
        let text = "日期,模型,Token\n2026-10-03,合成模型 🧪,123\n"
        let presenter = LocalTextExportPresenter(
            selectDestination: { _ in url },
            presentError: { _, _ in XCTFail("可写临时文件不应失败") })

        let outcome = presenter.export(title: "导出用量 CSV", filename: "usage.csv") { text }

        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
        XCTAssertNotNil(outcome.successFeedback)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["usage.csv"])
    }

    @MainActor
    func testDefaultWriterFailureDoesNotDamageExistingDestinationDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TokenMeter-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("existing.txt")
        let existing = Data("existing synthetic data".utf8)
        try existing.write(to: sentinel)
        var errorCalls = 0
        let presenter = LocalTextExportPresenter(
            selectDestination: { _ in directory },
            presentError: { _, _ in errorCalls += 1 })

        let outcome = presenter.export(title: "导出用量 CSV", filename: "usage.csv") { "new" }

        XCTAssertEqual(errorCalls, 1)
        XCTAssertNil(outcome.successFeedback)
        guard case .failed = outcome else { return XCTFail("目录不是可替换的文本文件") }
        XCTAssertEqual(try Data(contentsOf: sentinel), existing)
    }
}
