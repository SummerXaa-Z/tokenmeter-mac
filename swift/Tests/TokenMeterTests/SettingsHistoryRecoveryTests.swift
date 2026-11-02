import XCTest
@testable import TokenMeter

final class SettingsHistoryRecoveryTests: XCTestCase {
    private enum Failure: Error { case syntheticRead }

    @MainActor
    func testSettingsRetryFailurePreservesLastGoodAndSuccessfulRetryRestoresExport() async {
        let original = Self.snapshot(tokens: 17)
        let reader = HistorySnapshotReader(initial: original)
        reader.requireRevision(1)
        XCTAssertTrue(SettingsHistoryRecovery.canRetry(reader))
        let failed = await SettingsHistoryRecovery.retry(reader: reader, revision: 1, read: {
            throw Failure.syntheticRead
        })
        XCTAssertFalse(failed)
        XCTAssertEqual(reader.snapshot, original)
        XCTAssertFalse(reader.canUseSnapshot)
        XCTAssertNotNil(reader.error)
        XCTAssertTrue(SettingsHistoryRecovery.canRetry(reader))

        let recovered = await SettingsHistoryRecovery.retry(reader: reader, revision: 1, read: {
            Self.snapshot(tokens: 29)
        })
        XCTAssertTrue(recovered)
        XCTAssertEqual(reader.snapshot.daily.first?.total, 29)
        XCTAssertNil(reader.error)
        XCTAssertFalse(SettingsHistoryRecovery.canRetry(reader), "Already valid history must not prompt another retry")
    }

    @MainActor
    func testRetryNeverReadsWhileHistorySaveIsPending() async {
        let reader = HistorySnapshotReader(initial: Self.snapshot(tokens: 17))
        reader.requireRevision(2)
        reader.writesPending = true
        XCTAssertFalse(SettingsHistoryRecovery.canRetry(reader))
        let accepted = await SettingsHistoryRecovery.retry(reader: reader, revision: 2, read: {
            XCTFail("Pending-save history must not be read or treated as current")
            return .init()
        })
        XCTAssertFalse(accepted)
        XCTAssertFalse(reader.canUseSnapshot)
        XCTAssertEqual(reader.snapshot.daily.first?.total, 17)
    }

    @MainActor
    func testInFlightRetryCannotBeDuplicatedOrPublishAfterRevisionChanges() async {
        let started = expectation(description: "Synthetic settings read started")
        var continuation: CheckedContinuation<HistorySnapshotReader.Snapshot, Never>?
        let original = Self.snapshot(tokens: 17)
        let reader = HistorySnapshotReader(initial: original)
        reader.requireRevision(1)
        let first = Task {
            await SettingsHistoryRecovery.retry(reader: reader, revision: 1, read: {
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(SettingsHistoryRecovery.canRetry(reader))
        let duplicate = await SettingsHistoryRecovery.retry(reader: reader, revision: 1, read: {
            XCTFail("Repeated settings action must not create another read")
            return .init()
        })
        XCTAssertFalse(duplicate)
        reader.requireRevision(2)
        continuation?.resume(returning: Self.snapshot(tokens: 29))
        let accepted = await first.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(reader.snapshot, original)
        XCTAssertFalse(reader.canUseSnapshot)
        XCTAssertTrue(SettingsHistoryRecovery.canRetry(reader))
    }

    @MainActor
    func testConfirmedEmptyRecoveryIsValidWithoutInventingUsage() async {
        let reader = HistorySnapshotReader()
        let accepted = await SettingsHistoryRecovery.retry(reader: reader, revision: 0, read: { .init() })
        XCTAssertTrue(accepted)
        XCTAssertEqual(reader.snapshot, .init())
        XCTAssertTrue(reader.canUseSnapshot)
    }

    private static func snapshot(tokens: Int) -> HistorySnapshotReader.Snapshot {
        .init(daily: [.init(date: "2026-10-03", bySource: [.kimi: tokens], cost: 0)])
    }
}
