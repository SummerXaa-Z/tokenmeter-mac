import XCTest
@testable import TokenMeter

final class AlertLatchTests: XCTestCase {
    func testContinuousCrossingOnlyFiresOnceAndRecoveryRearms() {
        var latch = AlertLatch()

        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
        XCTAssertFalse(latch.shouldFire(key: "quota", crossed: true, enabled: true))
        XCTAssertFalse(latch.shouldFire(key: "quota", crossed: false, enabled: true))
        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
    }

    func testDisabledNotificationsDoNotConsumeTheNextCrossing() {
        var latch = AlertLatch()

        XCTAssertFalse(latch.shouldFire(key: "quota", crossed: true, enabled: false))
        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
    }

    func testDisablingNotificationsRearmsAnAlreadyFiredCrossing() {
        var latch = AlertLatch()

        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
        XCTAssertFalse(latch.shouldFire(key: "quota", crossed: true, enabled: false))
        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
    }

    func testRecoveryWhileDisabledStillRearmsTheAlert() {
        var latch = AlertLatch()

        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
        XCTAssertFalse(latch.shouldFire(key: "quota", crossed: false, enabled: false))
        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
    }

    func testResetRearmsAnExplicitlyDisabledAlertSource() {
        var latch = AlertLatch()

        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
        latch.reset(key: "quota")
        XCTAssertTrue(latch.shouldFire(key: "quota", crossed: true, enabled: true))
    }

    func testBalanceAlertRearmsWhenThresholdDisabledOrBalanceDataGone() {
        let lastGood = Balance(
            isAvailable: true, currency: "CNY",
            totalBalance: "8.50", grantedBalance: "8.50", toppedUpBalance: "0.00")

        // 关闭阈值（来源关闭或清零）与余额数据消失（清 Key 后置空）都重新
        // 布防；读取失败保留 last-good 余额时不复位，恢复后不重复提醒
        XCTAssertTrue(BalanceAlertPolicy.shouldRearm(threshold: 0, balance: nil))
        XCTAssertTrue(BalanceAlertPolicy.shouldRearm(threshold: 0, balance: lastGood))
        XCTAssertTrue(BalanceAlertPolicy.shouldRearm(threshold: 10, balance: nil))
        XCTAssertFalse(BalanceAlertPolicy.shouldRearm(threshold: 10, balance: lastGood))
    }
}
