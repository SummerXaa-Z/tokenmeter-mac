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

    func testOpenTargetMapsAlertsToTheirPages() {
        // 点横幅本身（默认动作）才跳转；各告警跳对应来源页
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: Notifier.weeklyDigestID,
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .dashboard)
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: "codex.quota.low",
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .source(.codex))
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: "claude.daily.over",
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .source(.claude))
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: "kimi.quota.low",
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .source(.kimi))
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: "deepseek.balance.low",
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .source(.deepseek))
        // 智谱/方舟额度只在总览露面;节奏预警 key 带窗口重置时刻,前缀匹配
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: "zhipu.quota.low",
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .dashboard)
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: "ark.quota.low",
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .dashboard)
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: "quota.pace.codex-weekly@1723",
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .dashboard)
    }

    func testOpenTargetIgnoresDerivedActionsAndUnknownIds() {
        // 派生动作（关闭/展开等）与未知通知不跳转,不抢焦点
        XCTAssertNil(Notifier.openTarget(
            identifier: Notifier.weeklyDigestID,
            actionIdentifier: UNNotificationDismissActionIdentifier))
        XCTAssertNil(Notifier.openTarget(
            identifier: "codex.quota.low",
            actionIdentifier: UNNotificationDismissActionIdentifier))
        XCTAssertNil(Notifier.openTarget(
            identifier: "update.available",
            actionIdentifier: UNNotificationDefaultActionIdentifier))
        // 周报通知键由发送方与路由共用，锁定不改名
        XCTAssertEqual(Notifier.weeklyDigestID, "weekly.digest")
    }
}
