import XCTest
@testable import TokenMeter

final class RefreshCoordinatorTests: XCTestCase {
    func testScheduledAndOverviewPlansCoverDeclaredEnabledSourcesAndAllSubscriptions() {
        let enabled = Set(HistorySource.allCases)
        let expected: [RefreshOperation] = [.deepseekBalance]
            + SourceCatalog.entries.map { .usage($0.source) }
            + [.kimiQuota, .zhipuQuota, .arkPlanQuota]
        XCTAssertEqual(RefreshPlan.make(scope: .overview, enabledSources: enabled).operations, expected)
        XCTAssertEqual(RefreshPlan.make(scope: .scheduled, enabledSources: enabled).operations, expected)
    }

    func testAccountPlanDoesNotDependOnCodingSourceOrMenubarSelection() {
        let expected: [RefreshOperation] = [.kimiQuota, .zhipuQuota, .arkPlanQuota]
        XCTAssertEqual(RefreshPlan.make(scope: .status(usageSources: []), enabledSources: []).operations, expected)
        XCTAssertEqual(RefreshPlan.make(scope: .scheduled, enabledSources: []).operations, expected)
        XCTAssertEqual(RefreshPlan.make(scope: .subscriptions, enabledSources: Set(HistorySource.allCases)).operations,
                       expected)
    }

    func testPlatformAndSelectedStatusPlansDoNotRefreshUnrequestedUsage() {
        let enabled: Set<HistorySource> = [.deepseek, .claude, .kimi]
        XCTAssertEqual(RefreshPlan.make(scope: .platform, enabledSources: enabled).operations,
                       [.deepseekBalance, .usage(.deepseek)])
        XCTAssertEqual(RefreshPlan.make(scope: .status(usageSources: [.claude, .codex]), enabledSources: enabled).operations,
                       [.usage(.claude), .kimiQuota, .zhipuQuota, .arkPlanQuota])
        XCTAssertEqual(RefreshPlan.make(scope: .platform, enabledSources: []).operations, [])
    }

    @MainActor
    func testRefreshCommandWaitsForDelayedPlatformUsageAndPropagatesForceToAllOperations() async {
        let started = expectation(description: "Delayed platform query started")
        var continuation: CheckedContinuation<Void, Never>?
        var completed = false
        var received: [RefreshOperation: Bool] = [:]
        let plan = RefreshPlan.make(scope: .overview, enabledSources: [.deepseek, .claude])
        let coordinator = RefreshCoordinator { operation, force in
            received[operation] = force
            if operation == .usage(.deepseek) {
                await withCheckedContinuation { waiting in
                    continuation = waiting
                    started.fulfill()
                }
            }
        }
        let task = Task {
            await coordinator.refresh(plan: plan, force: true)
            completed = true
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(completed, "Awaitable refresh cannot finish while the DeepSeek usage query is running")
        continuation?.resume()
        await task.value
        XCTAssertTrue(completed)
        XCTAssertEqual(Set(received.keys), Set(plan.operations))
        XCTAssertTrue(received.values.allSatisfy { $0 })
    }

    @MainActor
    func testRepeatedScheduledTicksCannotExtendSlowBatchAndManualForceStillRerunsOnce() async {
        let firstStarted = expectation(description: "First synthetic load started")
        let secondStarted = expectation(description: "Manual force rerun started")
        let manualJoined = expectation(description: "Manual command joined the running loader")
        let gate = ScheduledRefreshBatchGate()
        let completion = RefreshCompletionWaiter()
        var coalescer = ForcedRefreshCoalescer()
        var continuation: CheckedContinuation<Void, Never>?
        var loads = 0
        var manualCompleted = false
        let plan = RefreshPlan(operations: [.usage(.kimi)])
        let coordinator = RefreshCoordinator { _, force in
            guard coalescer.request(force: force) else {
                manualJoined.fulfill()
                await completion.wait()
                return
            }
            defer { completion.resumeAll() }
            while true {
                loads += 1
                await withCheckedContinuation { waiting in
                    continuation = waiting
                    if loads == 1 { firstStarted.fulfill() }
                    else { secondStarted.fulfill() }
                }
                guard coalescer.finish() else { break }
            }
        }
        let scheduled = Task {
            await gate.runIfIdle { await coordinator.refresh(plan: plan, force: true) }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let manual = Task {
            await coordinator.refresh(plan: plan, force: true)
            manualCompleted = true
        }
        await fulfillment(of: [manualJoined], timeout: 1)
        for _ in 0..<5 {
            let accepted = await gate.runIfIdle {
                await coordinator.refresh(plan: plan, force: true)
            }
            XCTAssertFalse(accepted)
        }
        XCTAssertFalse(manualCompleted)
        continuation?.resume()
        await fulfillment(of: [secondStarted], timeout: 1)
        for _ in 0..<5 {
            let accepted = await gate.runIfIdle {
                await coordinator.refresh(plan: plan, force: true)
            }
            XCTAssertFalse(accepted)
        }
        continuation?.resume()
        let scheduledAccepted = await scheduled.value
        XCTAssertTrue(scheduledAccepted)
        await manual.value

        XCTAssertEqual(loads, 2, "Automatic ticks must not enqueue an unbounded force rerun chain")
        XCTAssertTrue(manualCompleted)
        XCTAssertFalse(gate.isRunning)
        let nextTick = await gate.runIfIdle {}
        XCTAssertTrue(nextTick, "The gate must reopen after the finite scheduled batch finishes")
    }
}
