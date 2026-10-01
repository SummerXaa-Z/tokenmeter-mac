import XCTest
import UserNotifications
@testable import TokenMeter

final class NotifierTests: XCTestCase {
    func testDisabledNotificationsDoNotRequestAuthorization() {
        var requestCount = 0

        Notifier.requestAuthorizationIfEnabled(false) {
            requestCount += 1
        }

        XCTAssertEqual(requestCount, 0)
    }

    func testEnablingNotificationsRequestsAuthorizationOnce() {
        var requestCount = 0

        Notifier.requestAuthorizationIfEnabled(true) {
            requestCount += 1
        }

        XCTAssertEqual(requestCount, 1)
    }

    func testNotificationEnqueueRequiresBothAppSettingAndSystemAuthorization() {
        XCTAssertTrue(Notifier.shouldEnqueue(
            authorizationStatus: .authorized,
            notificationsEnabled: true
        ))
        XCTAssertTrue(Notifier.shouldEnqueue(
            authorizationStatus: .provisional,
            notificationsEnabled: true
        ))
        XCTAssertFalse(Notifier.shouldEnqueue(
            authorizationStatus: .authorized,
            notificationsEnabled: false
        ))
        XCTAssertFalse(Notifier.shouldEnqueue(
            authorizationStatus: .denied,
            notificationsEnabled: true
        ))
    }

    func testOverviewOpensOnlyForDigestBannerClick() {
        // 点横幅本身（默认动作）才打开总览；派生动作与其它通知不跳转
        XCTAssertTrue(Notifier.shouldOpenOverview(
            identifier: Notifier.weeklyDigestID,
            actionIdentifier: UNNotificationDefaultActionIdentifier))
        XCTAssertFalse(Notifier.shouldOpenOverview(
            identifier: Notifier.weeklyDigestID,
            actionIdentifier: UNNotificationDismissActionIdentifier))
        XCTAssertFalse(Notifier.shouldOpenOverview(
            identifier: "quota.warning",
            actionIdentifier: UNNotificationDefaultActionIdentifier))
        // 周报通知键由发送方与路由共用，锁定不改名
        XCTAssertEqual(Notifier.weeklyDigestID, "weekly.digest")
    }
}
