import XCTest
@testable import TokenMeter

final class QuotaWindowFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testCodexExpiredLowWindowDoesNotMaskActiveWindow() {
        let limits = codex(primaryReset: now, secondaryReset: now.addingTimeInterval(3600))
        let snapshot = SubscriptionQuotaSnapshot(codex: limits, now: now)
        XCTAssertEqual(snapshot.groups[0].periods.map(\.remainingPercent), [nil, 80])
        XCTAssertEqual(snapshot.groups[0].periods.map(\.isExpired), [true, false])
        XCTAssertEqual(SubscriptionQuotaAlert.codexWorstRemainingPercent(limits, now: now), 80)
        XCTAssertFalse(SubscriptionQuotaAlert.shouldNotify(
            remainingPercent: SubscriptionQuotaAlert.codexWorstRemainingPercent(limits, now: now)))
        XCTAssertEqual(snapshot.groups[0].observedAt, limits.asOf)
    }

    func testAllExpiredCodexWindowsAreUnknownRatherThanFullOrLow() {
        let limits = codex(primaryReset: now.addingTimeInterval(-1), secondaryReset: now)
        let periods = SubscriptionQuotaSnapshot(codex: limits, now: now).groups[0].periods
        XCTAssertTrue(periods.allSatisfy { $0.remainingPercent == nil && $0.isExpired && $0.pace == nil })
        XCTAssertNil(SubscriptionQuotaAlert.codexWorstRemainingPercent(limits, now: now))
        XCTAssertNil(QuotaWindowFreshness.remainingPercent(limits.primary!, now: now))
    }

    func testCodexMissingResetAndNonfinitePercentCannotBecomeQuotaFacts() {
        let missingReset = CodexRateWindow(usedPercent: 99, windowMinutes: 300,
                                           resetsAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(QuotaWindowFreshness.remainingPercent(missingReset, now: now))
        XCTAssertNil(QuotaWindowFreshness.remainingPercent(.nan, resetAt: nil, now: now))
        XCTAssertNil(QuotaWindowFreshness.remainingPercent(.infinity, resetAt: now.addingTimeInterval(1), now: now))
        XCTAssertFalse(SubscriptionQuotaAlert.shouldNotify(remainingPercent: .nan))
        // 不提供 reset 的官方服务仍可保留观测值，但不能推断重置或节奏。
        XCTAssertEqual(QuotaWindowFreshness.remainingPercent(5, resetAt: nil, now: now), 5)
    }

    func testKimiAndZhipuNormalizeAndAlertUsingTheSameExpirationRule() {
        let future = now.addingTimeInterval(3600)
        let kimi = KimiQuotaResult(
            summary: .init(name: "Weekly", window: .init(duration: 1, unit: .week),
                           used: 20, limit: 100, resetAt: stamp(future)),
            limits: [.init(name: "5h", window: .init(duration: 5, unit: .hour),
                           used: 99, limit: 100, resetAt: stamp(now))], extraUsage: nil)
        let zhipu = ZhipuQuotaResult(
            fiveHour: .init(usedPercent: 99, used: 99, total: 100, resetAt: now),
            weekly: .init(usedPercent: 20, used: 20, total: 100, resetAt: future))
        let observed = now.addingTimeInterval(-60)
        let snapshot = SubscriptionQuotaSnapshot(kimi: kimi, zhipu: zhipu,
                                                 kimiObservedAt: observed, zhipuObservedAt: observed, now: now)
        for group in snapshot.groups {
            XCTAssertEqual(group.periods.map(\.remainingPercent), [nil, 80])
            XCTAssertEqual(group.observedAt, observed)
        }
        XCTAssertEqual(SubscriptionQuotaAlert.kimiWorstRemainingPercent(kimi, now: now), 80)
        XCTAssertEqual(SubscriptionQuotaAlert.zhipuWorstRemainingPercent(zhipu, now: now), 80)
        XCTAssertNil(SubscriptionQuotaAlert.kimiWorstRemainingPercent(kimi, now: future))
        XCTAssertNil(SubscriptionQuotaAlert.zhipuWorstRemainingPercent(zhipu, now: future))
    }

    func testArkExpirationKeepsOnlyActiveSubscribedPeriodsAndFetchedTimestamp() throws {
        let future = now.addingTimeInterval(3600)
        let json = #"""
        [{"product":"agent-plan","subscribed":true,"periods":[
          {"label":"5h","percent":99,"reset_at":"\#(stamp(now))"},
          {"label":"weekly","percent":20,"reset_at":"\#(stamp(future))"}
        ]},{"product":"coding-plan","subscribed":false,"periods":[
          {"label":"weekly","percent":99,"reset_at":"\#(stamp(future))"}
        ]}]
        """#
        let ark = ArkPlanQuotaSnapshot(items: try ArkPlanQuotaService.parseItems(Data(json.utf8)),
                                       fetchedAt: now.addingTimeInterval(-60))
        let group = try XCTUnwrap(SubscriptionQuotaSnapshot(ark: ark, now: now).groups.first)
        XCTAssertEqual(group.periods.map(\.remainingPercent), [nil, 80])
        XCTAssertEqual(group.observedAt, ark.fetchedAt)
        XCTAssertEqual(SubscriptionQuotaAlert.arkWorstRemainingPercent(ark, now: now), 80)
        XCTAssertNil(SubscriptionQuotaAlert.arkWorstRemainingPercent(ark, now: future))
    }

    func testInMemorySnapshotCanExpireWithoutAnotherScanAndPaceAlertIsRemoved() {
        let reset = now.addingTimeInterval(3600)
        let limits = codex(primaryReset: reset, secondaryReset: reset)
        let snapshot = SubscriptionQuotaSnapshot(codex: limits, now: now)
        XCTAssertFalse(snapshot.groups[0].periods[0].isExpired)
        let later = snapshot.evaluated(at: reset)
        XCTAssertTrue(later.groups[0].periods.allSatisfy { $0.isExpired && $0.remainingPercent == nil })
        XCTAssertTrue(QuotaPaceAlert.items(snapshot, now: reset).isEmpty,
                      "Expired windows must leave the alert latch's active key set")
        XCTAssertTrue(QuotaPaceAlert.items(later, now: reset).isEmpty)
        XCTAssertEqual(later.groups[0].observedAt, limits.asOf)
    }

    private func codex(primaryReset: Date, secondaryReset: Date) -> CodexRateLimits {
        .init(limitId: "codex", limitName: nil,
              primary: .init(usedPercent: 99, windowMinutes: 300, resetsAt: primaryReset),
              secondary: .init(usedPercent: 20, windowMinutes: 10_080, resetsAt: secondaryReset),
              planType: "pro", asOf: now.addingTimeInterval(-60))
    }

    private func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
