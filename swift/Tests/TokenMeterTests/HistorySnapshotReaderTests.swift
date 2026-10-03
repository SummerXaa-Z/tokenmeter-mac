import XCTest
@testable import TokenMeter

final class HistorySnapshotReaderTests: XCTestCase {
    @MainActor
    func testInitializationDoesNotReadAndSuccessfulRevisionIsReadOnce() async {
        var reads = 0
        let value = Self.snapshot(tokens: 12)
        let reader = HistorySnapshotReader(read: { reads += 1; return value })
        XCTAssertEqual(reads, 0)

        await reader.refresh(revision: 0)
        await reader.refresh(revision: 0)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(reader.snapshot, value)
        XCTAssertFalse(reader.loading)

        await reader.refresh(revision: 1)
        XCTAssertEqual(reads, 2)
        await reader.refresh(revision: 1, force: true)
        XCTAssertEqual(reads, 3)
    }

    @MainActor
    func testConcurrentSameRevisionWaitsForOneRead() async {
        let pending = PendingHistoryRead(started: expectation(description: "Read started"))
        var reads = 0
        let reader = HistorySnapshotReader(read: { reads += 1; return try await pending.load() })
        let first = Task { await reader.refresh(revision: 4) }
        await fulfillment(of: [pending.started], timeout: 1)
        let waiterStarted = expectation(description: "Second refresh entered")
        let second = Task {
            waiterStarted.fulfill()
            await reader.refresh(revision: 4)
        }
        await fulfillment(of: [waiterStarted], timeout: 1)
        XCTAssertTrue(reader.loading)
        XCTAssertEqual(reads, 1)

        let value = Self.snapshot(tokens: 24)
        pending.complete(.success(value))
        await first.value
        await second.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(reader.snapshot, value)
        XCTAssertFalse(reader.loading)
    }

    @MainActor
    func testOlderSuccessCannotOverwriteNewerSnapshot() async {
        let old = PendingHistoryRead(started: expectation(description: "Old read started"))
        let new = PendingHistoryRead(started: expectation(description: "New read started"))
        var reads = 0
        let reader = HistorySnapshotReader(read: {
            reads += 1
            return try await (reads == 1 ? old : new).load()
        })
        let first = Task { await reader.refresh(revision: 1) }
        await fulfillment(of: [old.started], timeout: 1)
        let second = Task { await reader.refresh(revision: 2) }
        await fulfillment(of: [new.started], timeout: 1)
        let latest = Self.snapshot(tokens: 200)
        new.complete(.success(latest))
        await second.value
        old.complete(.success(Self.snapshot(tokens: 100)))
        await first.value

        XCTAssertEqual(reader.snapshot, latest)
        XCTAssertNil(reader.error)
        XCTAssertFalse(reader.loading)
    }

    @MainActor
    func testOlderFailureCannotReplaceNewerSuccessOrItsLoadingState() async {
        let old = PendingHistoryRead(started: expectation(description: "Old read started"))
        let new = PendingHistoryRead(started: expectation(description: "New read started"))
        var reads = 0
        let reader = HistorySnapshotReader(read: {
            reads += 1
            return try await (reads == 1 ? old : new).load()
        })
        let first = Task { await reader.refresh(revision: 1) }
        await fulfillment(of: [old.started], timeout: 1)
        let second = Task { await reader.refresh(revision: 2) }
        await fulfillment(of: [new.started], timeout: 1)
        old.complete(.failure(SyntheticHistoryFailure.unavailable))
        await first.value
        XCTAssertTrue(reader.loading, "Old failure must not end the current read")
        XCTAssertNil(reader.error)
        new.complete(.success(Self.snapshot(tokens: 42)))
        await second.value
        XCTAssertEqual(reader.snapshot.daily.first?.total, 42)
        XCTAssertNil(reader.error)
    }

    @MainActor
    func testFailureRetainsBothHistoriesAndSameRevisionCanRecover() async {
        let original = Self.snapshot(tokens: 90)
        let recovered = Self.snapshot(tokens: 95)
        var reads = 0
        let reader = HistorySnapshotReader(initial: original, read: {
            reads += 1
            if reads == 1 { throw SyntheticHistoryFailure.unavailable }
            return recovered
        })
        await reader.refresh(revision: 8)
        XCTAssertEqual(reader.snapshot, original)
        XCTAssertNotNil(reader.error)
        XCTAssertFalse(reader.loading)

        await reader.refresh(revision: 8)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(reader.snapshot, recovered)
        XCTAssertNil(reader.error)
        await reader.refresh(revision: 8)
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testConfirmedEmptyReplacesLastGoodButReadFailureDoesNot() async {
        var fails = true
        let reader = HistorySnapshotReader(initial: Self.snapshot(tokens: 19), read: {
            if fails { throw SyntheticHistoryFailure.unavailable }
            return .init()
        })
        await reader.refresh(revision: 1)
        XCTAssertEqual(reader.snapshot.daily.first?.total, 19)
        XCTAssertNotNil(reader.error)
        fails = false
        await reader.refresh(revision: 1, force: true)
        XCTAssertEqual(reader.snapshot, .init())
        XCTAssertNil(reader.error)
    }

    @MainActor
    func testCancelledViewWaiterDoesNotCancelSharedReadOrDuplicateIt() async {
        let pending = PendingHistoryRead(started: expectation(description: "Read started"))
        var reads = 0
        let reader = HistorySnapshotReader(read: { reads += 1; return try await pending.load() })
        let viewTask = Task { await reader.refresh(revision: 3) }
        await fulfillment(of: [pending.started], timeout: 1)
        viewTask.cancel()
        pending.complete(.success(Self.snapshot(tokens: 33)))
        await viewTask.value
        await reader.refresh(revision: 3)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(reader.snapshot.daily.first?.total, 33)
        XCTAssertFalse(reader.loading)
    }

    @MainActor
    func testLargeInjectedHistoryRetainsFullWindowForAllConsumers() async throws {
        let start = try XCTUnwrap(DateUtil.date(from: "2025-01-01"))
        let daily = (0..<600).map { index -> HistoryStore.DayPoint in
            let date = Calendar.current.date(byAdding: .day, value: index, to: start)!
            return .init(date: DateUtil.key(date), bySource: [.codex: 100], cost: 0)
        }
        let models = daily.map {
            ModelUsageDay(date: $0.date, bySource: [.codex: .init(
                models: ["gpt-5": ModelTokenTally(input: 100)], skills: ["review": 1], sessions: 1)])
        }
        let snapshot = HistorySnapshotReader.Snapshot(daily: daily, models: models)
        var reads = 0
        let reader = HistorySnapshotReader(read: { reads += 1; return snapshot })
        await reader.refresh(revision: 9)
        // 重复渲染/换范围只读同一值，不触发 reader 的 IO。
        for _ in 0..<10 {
            let summary = CodingModelDetail.summary(
                source: .codex, model: "gpt-5", liveDayModels: nil,
                persisted: reader.snapshot.models, todayKey: daily.last!.date, windowDays: 30)
            XCTAssertEqual(summary?.days.count, 30)
            XCTAssertEqual(summary?.tally.total, 3_000)
        }
        XCTAssertEqual(reader.snapshot.daily.count, 600)
        XCTAssertEqual(reader.snapshot.models.count, 600)
        XCTAssertEqual(reads, 1)
    }

    private static func snapshot(tokens: Int) -> HistorySnapshotReader.Snapshot {
        .init(
            daily: [.init(date: "2026-08-12", bySource: [.codex: tokens], cost: 0)],
            models: [.init(date: "2026-08-12", bySource: [.codex: .init(
                models: ["gpt-5": ModelTokenTally(input: tokens)], sessions: 1)])])
    }

    @MainActor
    func testCompletionReportsRecoveryWithoutClearingIndependentWriteFailures() async {
        var fails = true
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in throw SyntheticHistoryFailure.unavailable },
            writeModels: { _, _, _, _ in false }))
        let reader = HistorySnapshotReader(read: {
            if fails { throw SyntheticHistoryFailure.unavailable }
            return .init()
        })
        await reader.refresh(revision: 1)
        reader.reportCurrentCompletion(reader.completion) { state.reportHistoryReadOutcome(succeeded: $0) }
        XCTAssertNotNil(state.historyPersistenceError)

        fails = false
        await reader.refresh(revision: 1)
        reader.reportCurrentCompletion(reader.completion) { state.reportHistoryReadOutcome(succeeded: $0) }
        XCTAssertNil(state.historyPersistenceError, "Successful reread clears the stale read warning")

        state.kimiEnabled = true
        XCTAssertTrue(state.acceptKimiCollection(KimiUsageResult(
            days: [.init(date: "2026-10-01", inputTokens: 70)], models: [], todayHours: [])))
        XCTAssertNotNil(state.historyPersistenceError)
        await reader.refresh(revision: 2)
        reader.reportCurrentCompletion(reader.completion) { state.reportHistoryReadOutcome(succeeded: $0) }
        XCTAssertNotNil(state.historyPersistenceError, "Reader success must not clear a failed write")
    }

    @MainActor
    func testStaleOrStillLoadingCompletionIsNotReported() async {
        let pending = PendingHistoryRead(started: expectation(description: "New read started"))
        var reads = 0
        let reader = HistorySnapshotReader(read: {
            reads += 1
            if reads == 1 { return .init() }
            return try await pending.load()
        })
        await reader.refresh(revision: 1)
        let previous = reader.completion
        let task = Task { await reader.refresh(revision: 2) }
        await fulfillment(of: [pending.started], timeout: 1)
        var reports: [Bool] = []
        reader.reportCurrentCompletion(previous) { reports.append($0) }
        XCTAssertTrue(reports.isEmpty, "A previous completion cannot report while the current read is running")
        pending.complete(.failure(SyntheticHistoryFailure.unavailable))
        await task.value
        reader.reportCurrentCompletion(previous) { reports.append($0) }
        XCTAssertTrue(reports.isEmpty, "The old success cannot overwrite the new failure warning")
        reader.reportCurrentCompletion(reader.completion) { reports.append($0) }
        XCTAssertEqual(reports, [false])
    }
}

private enum SyntheticHistoryFailure: Error { case unavailable }

@MainActor
private final class PendingHistoryRead {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<HistorySnapshotReader.Snapshot, Error>?

    init(started: XCTestExpectation) { self.started = started }

    func load() async throws -> HistorySnapshotReader.Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func complete(_ result: Result<HistorySnapshotReader.Snapshot, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
