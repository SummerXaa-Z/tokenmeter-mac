import XCTest
@testable import TokenMeter

final class SubscriptionQuotaAlertTests: XCTestCase {
    private func kimiRow(
        _ used: Int, _ limit: Int,
        window: KimiQuotaWindow? = nil
    ) -> KimiQuotaRow {
        KimiQuotaRow(name: nil, window: window, used: used, limit: limit, resetAt: nil)
    }

    // MARK: - Kimi 最坏窗口

    func testKimiPicksWorstAcrossSummaryAndLimits() {
        let result = KimiQuotaResult(
            summary: kimiRow(20, 100, window: KimiQuotaWindow(duration: 1, unit: .week)),
            limits: [
                kimiRow(95, 100, window: KimiQuotaWindow(duration: 5, unit: .hour)),
                kimiRow(50, 100, window: KimiQuotaWindow(duration: 1, unit: .day)),
            ],
            extraUsage: nil
        )
        XCTAssertEqual(SubscriptionQuotaAlert.kimiWorstRemainingPercent(result), 5)
    }

    func testKimiReturnsNilWhenNoUsableWindow() {
        // limit=0（如需网页查看的会员月额度）不产生剩余口径
        let result = KimiQuotaResult(
            summary: nil,
            limits: [kimiRow(3, 0)],
            extraUsage: nil
        )
        XCTAssertNil(SubscriptionQuotaAlert.kimiWorstRemainingPercent(result))
    }

    func testKimiSummaryOnly() {
        let result = KimiQuotaResult(
            summary: kimiRow(40, 100), limits: [], extraUsage: nil)
        XCTAssertEqual(SubscriptionQuotaAlert.kimiWorstRemainingPercent(result), 60)
    }

    func testKimiClampsOutOfRangeBackendValues() {
        // used > limit 收敛到剩余 0，不产生负数
        let result = KimiQuotaResult(
            summary: kimiRow(130, 100), limits: [], extraUsage: nil)
        XCTAssertEqual(SubscriptionQuotaAlert.kimiWorstRemainingPercent(result), 0)
    }

    // MARK: - 智谱最坏窗口

    func testZhipuPicksWorstAcrossAllTiers() {
        let result = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(
                usedPercent: 75, used: nil, total: nil, resetAt: nil),
            weekly: ZhipuQuotaTier(
                usedPercent: 44, used: nil, total: nil, resetAt: nil),
            toolCalls: ZhipuQuotaTier(
                usedPercent: 72, used: nil, total: nil, resetAt: nil),
            level: "pro"
        )
        XCTAssertEqual(SubscriptionQuotaAlert.zhipuWorstRemainingPercent(result), 25)
    }

    func testZhipuClampsOverfullUsageToZero() {
        let result = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(
                usedPercent: 130, used: nil, total: nil, resetAt: nil),
            weekly: nil, toolCalls: nil, level: nil)
        XCTAssertEqual(SubscriptionQuotaAlert.zhipuWorstRemainingPercent(result), 0)
    }

    func testZhipuToolCallsAloneCounts() {
        let result = ZhipuQuotaResult(
            fiveHour: nil,
            weekly: nil,
            toolCalls: ZhipuQuotaTier(
                usedPercent: 99, used: 99, total: 100, resetAt: nil),
            level: nil
        )
        XCTAssertEqual(SubscriptionQuotaAlert.zhipuWorstRemainingPercent(result), 1)
    }

    func testZhipuReturnsNilWhenAllTiersMissing() {
        XCTAssertNil(SubscriptionQuotaAlert.zhipuWorstRemainingPercent(
            ZhipuQuotaResult(fiveHour: nil, weekly: nil, toolCalls: nil, level: nil)))
    }

    // MARK: - 方舟最坏窗口
    // ArkPlanQuotaItem 自定义了 init(from:)（memberwise init 被抑制），
    // 测试与 SubscriptionQuotaSnapshotTests 一致走 JSON 解码构造。

    private func arkSnapshot(_ json: String) throws -> ArkPlanQuotaSnapshot {
        ArkPlanQuotaSnapshot(
            items: try ArkPlanQuotaService.parseItems(Data(json.utf8)),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testArkPicksWorstAcrossSubscribedItemsAndPeriods() throws {
        // arkcli 的 percent 是"已用"口径：agent-plan 5h 已用 95 → 剩 5，为最坏
        let snapshot = try arkSnapshot(#"""
        [
          {"product":"coding-plan","subscribed":true,
           "periods":[{"label":"weekly","percent":30},{"label":"monthly","percent":60}]},
          {"product":"agent-plan","subscribed":true,
           "periods":[{"label":"5h","percent":95}]},
          {"product":"agent-plan-team","subscribed":false,
           "periods":[{"label":"5h","percent":99.9}]}
        ]
        """#)
        XCTAssertEqual(SubscriptionQuotaAlert.arkWorstRemainingPercent(snapshot), 5)
    }

    func testArkIgnoresPeriodsWithoutPercentAndEmptySnapshot() throws {
        // percent 缺失（如仅有 used/total 的窗口）与未订阅条目都不产生口径
        let snapshot = try arkSnapshot(#"""
        [
          {"product":"coding-plan","subscribed":true,
           "periods":[{"label":"monthly","percent":90},
                      {"label":"session","used":3,"total":10}]}
        ]
        """#)
        XCTAssertEqual(SubscriptionQuotaAlert.arkWorstRemainingPercent(snapshot), 10)

        let empty = ArkPlanQuotaSnapshot(items: [], fetchedAt: Date())
        XCTAssertNil(SubscriptionQuotaAlert.arkWorstRemainingPercent(empty))
    }

    // MARK: - 阈值线

    func testNotifyThresholdBoundaries() {
        XCTAssertFalse(SubscriptionQuotaAlert.shouldNotify(remainingPercent: nil))
        XCTAssertFalse(SubscriptionQuotaAlert.shouldNotify(remainingPercent: 10.5))
        XCTAssertTrue(SubscriptionQuotaAlert.shouldNotify(remainingPercent: 10))
        XCTAssertTrue(SubscriptionQuotaAlert.shouldNotify(remainingPercent: 0))
    }

    func testTintThresholdsMatchCodexLines() {
        XCTAssertTrue(SubscriptionQuotaAlert.isCritical(10))
        XCTAssertFalse(SubscriptionQuotaAlert.isCritical(10.5))
        XCTAssertTrue(SubscriptionQuotaAlert.isWarn(30))
        XCTAssertFalse(SubscriptionQuotaAlert.isWarn(30.5))
        // critical 必然也是 warn 线内
        XCTAssertTrue(SubscriptionQuotaAlert.isWarn(5))
    }
}
