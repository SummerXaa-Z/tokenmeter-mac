import Foundation
import XCTest
@testable import TokenMeter

final class HistoryWriteSchedulerTests: XCTestCase {
    private enum Failure: Error { case syntheticDisk }

    @MainActor
    func testSlowWriteRunsOffMainThreadAndMainActorCanAdvanceBeforeCompletion() async throws {
        let scheduler = HistoryWriteScheduler()
        let started = expectation(description: "Background disk operation started")
        let heartbeat = expectation(description: "Main actor advanced during slow disk operation")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = WriteEvents()
        var completed = false
        let write = scheduler.enqueue(operation: {
            probe.append("write", onMainThread: Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return true
        }, completion: { _ in
            XCTAssertTrue(Thread.isMainThread, "Publication must return to the main actor")
            completed = true
        })
        await fulfillment(of: [started], timeout: 3)
        let mainTask = Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 3)
        await mainTask.value
        XCTAssertFalse(completed, "Slow IO must not block unrelated main-actor work")
        XCTAssertEqual(probe.mainThreadFlags, [false])
        release.signal()
        let result = await write.value
        XCTAssertTrue(try result.get())
        await scheduler.flush()
        XCTAssertTrue(completed)
    }

    @MainActor
    func testWritesAndCompletionsCommitInSubmissionOrder() async {
        let scheduler = HistoryWriteScheduler()
        let probe = WriteEvents()
        for index in 0..<5 {
            scheduler.enqueue(operation: {
                probe.append("write-\(index)", onMainThread: Thread.isMainThread)
                return true
            }, completion: { _ in
                probe.append("complete-\(index)", onMainThread: Thread.isMainThread)
            })
        }
        await scheduler.flush()
        XCTAssertEqual(probe.events, (0..<5).flatMap { ["write-\($0)", "complete-\($0)"] })
        XCTAssertEqual(probe.mainThreadFlags, (0..<5).flatMap { _ in [false, true] })
    }

    @MainActor
    func testFlushWaitsForTasksAddedWhileAnEarlierWriteIsPending() async {
        let scheduler = HistoryWriteScheduler()
        let firstStarted = expectation(description: "First queued write started")
        let flushEntered = expectation(description: "Flush entered")
        let secondStarted = expectation(description: "Later queued write started")
        let firstRelease = DispatchSemaphore(value: 0)
        let secondRelease = DispatchSemaphore(value: 0)
        defer { firstRelease.signal(); secondRelease.signal() }
        var flushed = false
        scheduler.enqueue(operation: {
            firstStarted.fulfill()
            _ = firstRelease.wait(timeout: .now() + 5)
            return true
        }, completion: { _ in })
        await fulfillment(of: [firstStarted], timeout: 3)
        let flush = Task {
            flushEntered.fulfill()
            await scheduler.flush()
            flushed = true
        }
        await fulfillment(of: [flushEntered], timeout: 3)
        scheduler.enqueue(operation: {
            secondStarted.fulfill()
            _ = secondRelease.wait(timeout: .now() + 5)
            return true
        }, completion: { _ in })
        firstRelease.signal()
        await fulfillment(of: [secondStarted], timeout: 3)
        XCTAssertFalse(flushed, "Flush must notice the tail added after it began waiting")
        secondRelease.signal()
        await flush.value
        XCTAssertTrue(flushed)
    }

    @MainActor
    func testSkipIsCheckedAfterEarlierWorkAndBalancesInFlightWithoutPublishingSuccess() async throws {
        let scheduler = HistoryWriteScheduler()
        let started = expectation(description: "Earlier write suspended")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = WriteEvents()
        var inputIsCurrent = true
        var inFlight = 2
        var skips = 0
        scheduler.enqueue(operation: {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return true
        }, completion: { _ in inFlight -= 1 })
        let skipped = scheduler.enqueue(shouldWrite: { inputIsCurrent }, onSkip: {
            XCTAssertTrue(Thread.isMainThread)
            inFlight -= 1
            skips += 1
        }, operation: {
            probe.append("obsolete-write", onMainThread: Thread.isMainThread)
            return true
        }, completion: { _ in
            XCTFail("Skipped writes must not publish a successful persistence outcome")
            inFlight -= 1
        })
        await fulfillment(of: [started], timeout: 3)
        inputIsCurrent = false
        release.signal()
        let result = await skipped.value
        XCTAssertFalse(try result.get())
        await scheduler.flush()
        XCTAssertEqual(probe.events, [])
        XCTAssertEqual(skips, 1)
        XCTAssertEqual(inFlight, 0)
    }

    @MainActor
    func testUnchangedAcceptedRefreshDoesNotAdvanceHistoryRevisionOrRereadSnapshot() async {
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in false }, writeModels: { _, _, _, _ in false }))
        state.kimiEnabled = true
        var reads = 0
        let reader = HistorySnapshotReader(read: { reads += 1; return .init() })
        await reader.refresh(revision: state.historyRevision)
        let initialRevision = state.historyRevision
        XCTAssertTrue(state.acceptKimiCollection(kimiFixture()))
        XCTAssertEqual(state.historyWritesInFlight, 1)
        await state.flushHistoryWrites()

        XCTAssertEqual(state.historyWritesInFlight, 0)
        XCTAssertEqual(state.historyRevision, initialRevision)
        await reader.refresh(revision: state.historyRevision)
        XCTAssertEqual(reads, 1, "No-change scans must not reload the complete retained history")
    }

    @MainActor
    func testPartialFailureAdvancesReadAndUnchangedRecoveryTriggersOneFurtherRead() async {
        let behavior = PersistenceBehavior()
        behavior.modelFails = true
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in behavior.dailyChanges },
            writeModels: { _, _, _, _ in
                if behavior.modelFails { throw Failure.syntheticDisk }
                return false
            }))
        state.kimiEnabled = true
        var reads = 0
        let reader = HistorySnapshotReader(read: { reads += 1; return .init() })
        await reader.refresh(revision: state.historyRevision)
        XCTAssertTrue(state.acceptKimiCollection(kimiFixture()))
        await state.flushHistoryWrites()
        let failedRevision = state.historyRevision
        XCTAssertEqual(failedRevision, 1)
        XCTAssertNotNil(state.historyPersistenceError)
        XCTAssertNotNil(state.kimi.result)
        await reader.refresh(revision: failedRevision)
        XCTAssertEqual(reads, 2, "Successful daily/partial model commits still require a strict reread")

        behavior.modelFails = false
        behavior.dailyChanges = false
        XCTAssertTrue(state.acceptKimiCollection(kimiFixture()))
        await state.flushHistoryWrites()
        XCTAssertEqual(state.historyRevision, failedRevision + 1)
        XCTAssertNil(state.historyPersistenceError)
        await reader.refresh(revision: state.historyRevision)
        XCTAssertEqual(reads, 3, "Recovery needs a reread even when the retry itself changes no bytes")

        XCTAssertTrue(state.acceptKimiCollection(kimiFixture()))
        await state.flushHistoryWrites()
        await reader.refresh(revision: state.historyRevision)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(state.historyWritesInFlight, 0)
    }

    @MainActor
    func testFailedDailyWriteBeforeAnyCommitDoesNotFabricateChangedHistory() async {
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in throw Failure.syntheticDisk },
            writeModels: { _, _, _, _ in XCTFail("Models cannot run after daily failure"); return true }))
        state.kimiEnabled = true
        let initialRevision = state.historyRevision
        XCTAssertTrue(state.acceptKimiCollection(kimiFixture()))
        await state.flushHistoryWrites()
        XCTAssertEqual(state.historyRevision, initialRevision)
        XCTAssertNotNil(state.historyPersistenceError)
        XCTAssertEqual(state.historyWritesInFlight, 0)
        XCTAssertNotNil(state.kimi.result)
    }

    @MainActor
    func testOrderedReadWaitsForWholeWriteAndBlocksLaterWritesBetweenFiles() async throws {
        let scheduler = HistoryWriteScheduler()
        let probe = WriteEvents()
        let firstStarted = expectation(description: "Daily write started")
        let readEnqueued = expectation(description: "Read enqueued behind write")
        let readStarted = expectation(description: "Paired read started")
        let writeRelease = DispatchSemaphore(value: 0)
        let readRelease = DispatchSemaphore(value: 0)
        defer { writeRelease.signal(); readRelease.signal() }
        scheduler.enqueue(operation: {
            probe.append("write-daily", onMainThread: Thread.isMainThread)
            firstStarted.fulfill()
            _ = writeRelease.wait(timeout: .now() + 5)
            probe.append("write-models", onMainThread: Thread.isMainThread)
            return true
        }, completion: { _ in })
        await fulfillment(of: [firstStarted], timeout: 3)
        let read = Task {
            readEnqueued.fulfill()
            return try await scheduler.read {
                probe.append("read-daily", onMainThread: Thread.isMainThread)
                readStarted.fulfill()
                _ = readRelease.wait(timeout: .now() + 5)
                probe.append("read-models", onMainThread: Thread.isMainThread)
                return 7
            }
        }
        await fulfillment(of: [readEnqueued], timeout: 3)
        writeRelease.signal()
        await fulfillment(of: [readStarted], timeout: 3)
        scheduler.enqueue(operation: {
            probe.append("later-write", onMainThread: Thread.isMainThread)
            return true
        }, completion: { _ in })
        XCTAssertEqual(probe.events, ["write-daily", "write-models", "read-daily"])
        readRelease.signal()
        let value = try await read.value
        await scheduler.flush()
        XCTAssertEqual(value, 7)
        XCTAssertEqual(probe.events, ["write-daily", "write-models", "read-daily", "read-models", "later-write"])
        XCTAssertTrue(probe.mainThreadFlags.allSatisfy { !$0 })
    }

    @MainActor
    func testFailedOrderedReadDoesNotPoisonSubsequentWrite() async {
        let scheduler = HistoryWriteScheduler()
        do {
            let _: Int = try await scheduler.read { throw Failure.syntheticDisk }
            XCTFail("Read failures must propagate")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        var completed = false
        scheduler.enqueue(operation: { true }, completion: { _ in completed = true })
        await scheduler.flush()
        XCTAssertTrue(completed)
    }

    private func kimiFixture() -> KimiUsageResult {
        .init(days: [.init(date: "2026-10-03", inputTokens: 7)], models: [], todayHours: [],
              dayModels: ["2026-10-03": ["synthetic-model": .init(input: 7)]])
    }
}

private final class WriteEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, Bool)] = []

    func append(_ event: String, onMainThread: Bool) {
        lock.lock(); defer { lock.unlock() }
        values.append((event, onMainThread))
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.map { $0.0 }
    }

    var mainThreadFlags: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return values.map { $0.1 }
    }
}

private final class PersistenceBehavior: @unchecked Sendable {
    private let lock = NSLock()
    private var failModel = false
    private var changeDaily = true

    var modelFails: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failModel }
        set { lock.lock(); defer { lock.unlock() }; failModel = newValue }
    }

    var dailyChanges: Bool {
        get { lock.lock(); defer { lock.unlock() }; return changeDaily }
        set { lock.lock(); defer { lock.unlock() }; changeDaily = newValue }
    }
}
