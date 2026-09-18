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
}
