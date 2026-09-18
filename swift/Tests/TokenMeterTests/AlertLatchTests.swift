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
}
