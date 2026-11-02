import XCTest
@testable import TokenMeter

final class SettingsUsageCSVExporterTests: XCTestCase {
    @MainActor
    func testUninitializedOrFailedReaderNeverOpensPanelOrExportsFalseZero() async {
        var selections = 0
        var writes = 0
        let presenter = Self.presenter(onSelect: { selections += 1 }, onWrite: { _ in writes += 1 })
        let reader = HistorySnapshotReader(read: { throw SyntheticExportFailure.unavailable })
        XCTAssertFalse(reader.hasSuccessfulRead)
        let initial = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)
        XCTAssertNotNil(initial)
        XCTAssertEqual(selections, 0)

        await reader.refresh(revision: 1)
        XCTAssertFalse(reader.hasSuccessfulRead)
        XCTAssertFalse(reader.canUseSnapshot)
        let failed = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)
        XCTAssertEqual(failed, reader.unavailableMessage)
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testConfirmedEmptyCanExportAndRecoveryRestoresExport() async {
        var fails = true
        var selections = 0
        var texts: [String] = []
        let presenter = Self.presenter(onSelect: { selections += 1 }, onWrite: { texts.append($0) })
        let reader = HistorySnapshotReader(read: {
            if fails { throw SyntheticExportFailure.unavailable }
            return .init()
        })
        await reader.refresh(revision: 1)
        _ = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)
        XCTAssertEqual(selections, 0)
        fails = false
        await reader.refresh(revision: 1)
        XCTAssertTrue(reader.hasSuccessfulRead)
        XCTAssertTrue(reader.canUseSnapshot)
        let status = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)
        XCTAssertNotNil(status)
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(texts.count, 1)
        XCTAssertFalse(texts[0].isEmpty, "A confirmed empty dataset still has a valid CSV schema")
    }

    @MainActor
    func testLastGoodIsNotExportableDuringLoadingOrAfterFailure() async {
        let pending = PendingExportHistory(started: expectation(description: "Read started"))
        let reader = HistorySnapshotReader(initial: .init(), read: { try await pending.load() })
        XCTAssertTrue(reader.canUseSnapshot)
        let task = Task { await reader.refresh(revision: 2) }
        await fulfillment(of: [pending.started], timeout: 1)
        XCTAssertFalse(reader.canUseSnapshot)
        var selections = 0
        let presenter = Self.presenter(onSelect: { selections += 1 }, onWrite: { _ in XCTFail("Unexpected write") })
        _ = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)
        XCTAssertEqual(selections, 0)
        pending.fail()
        await task.value
        XCTAssertTrue(reader.hasSuccessfulRead)
        XCTAssertFalse(reader.canUseSnapshot)
        _ = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)
        XCTAssertEqual(selections, 0)
    }

    @MainActor
    func testRevisionChangeWhilePanelIsOpenRejectsOldSnapshotWithoutWriting() async {
        let snapshot = HistorySnapshotReader.Snapshot(daily: [
            .init(date: "2026-10-03", bySource: [.codex: 17], cost: 0)
        ])
        let reader = HistorySnapshotReader(read: { snapshot })
        await reader.refresh(revision: 1)
        XCTAssertTrue(reader.canUseSnapshot)
        var writes = 0
        var errors: [String] = []
        let presenter = Self.presenter(
            onSelect: { reader.requireRevision(2) },
            onWrite: { _ in writes += 1 },
            onError: { errors.append($0.localizedDescription) })

        let status = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)

        XCTAssertFalse(reader.canUseSnapshot)
        XCTAssertEqual(reader.snapshot, snapshot, "Retained display history is not an exportable current snapshot")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(errors, [reader.unavailableMessage])
        XCTAssertEqual(status, "导出失败：\(reader.unavailableMessage)")
    }

    @MainActor
    func testSaveBeginningWhilePanelIsOpenBlocksExportUntilCurrentSnapshotIsReady() {
        let reader = HistorySnapshotReader(initial: .init(daily: [
            .init(date: "2026-10-03", bySource: [.kimi: 29], cost: 0)
        ]))
        var writes = 0
        var errors: [String] = []
        let presenter = Self.presenter(
            onSelect: { reader.writesPending = true },
            onWrite: { _ in writes += 1 },
            onError: { errors.append($0.localizedDescription) })

        let status = SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter)

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(errors, [reader.unavailableMessage])
        XCTAssertEqual(status, "导出失败：\(reader.unavailableMessage)")
    }

    @MainActor
    func testCancellingAfterRevisionChangesRemainsSilentAndDoesNotWrite() {
        let reader = HistorySnapshotReader(initial: .init())
        let presenter = LocalTextExportPresenter(
            selectDestination: { _ in reader.requireRevision(2); return nil },
            write: { _, _ in XCTFail("Cancellation must not write old or empty history") },
            presentError: { _, _ in XCTFail("Cancellation must not present a stale-history error") })

        XCTAssertNil(SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter))
        XCTAssertFalse(reader.canUseSnapshot)
    }

    @MainActor
    func testCancellingPanelPreservesNoWriteAndReturnsNoFeedback() {
        let reader = HistorySnapshotReader(initial: .init(), read: { XCTFail("Unexpected read"); return .init() })
        let presenter = LocalTextExportPresenter(
            selectDestination: { _ in nil },
            write: { _, _ in XCTFail("Unexpected write") },
            presentError: { _, _ in XCTFail("Unexpected alert") })
        XCTAssertNil(SettingsUsageCSVExporter.run(reader: reader, plans: [], range: .all, presenter: presenter))
    }

    @MainActor
    private static func presenter(
        onSelect: @escaping () -> Void, onWrite: @escaping (String) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> LocalTextExportPresenter {
        LocalTextExportPresenter(
            selectDestination: { _ in onSelect(); return URL(fileURLWithPath: "/synthetic/usage.csv") },
            write: { text, _ in onWrite(text) },
            presentError: { error, _ in
                if let onError { onError(error) } else { XCTFail("Unexpected error alert") }
            },
            now: { Date(timeIntervalSince1970: 0) })
    }
}

private enum SyntheticExportFailure: Error { case unavailable }

@MainActor
private final class PendingExportHistory {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<HistorySnapshotReader.Snapshot, Error>?
    init(started: XCTestExpectation) { self.started = started }
    func load() async throws -> HistorySnapshotReader.Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func fail() { continuation?.resume(throwing: SyntheticExportFailure.unavailable); continuation = nil }
}
