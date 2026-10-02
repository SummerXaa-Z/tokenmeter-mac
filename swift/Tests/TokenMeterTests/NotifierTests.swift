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

    func testWeeklyDigestNotificationIDCarriesSummarizedWeek() {
        // 按周留痕:所述周进 identifier,不同周不同键,通知中心互不顶替
        XCTAssertEqual(Notifier.weeklyDigestID(forWeek: "2026-W39"), "weekly.digest.2026-W39")
        XCTAssertNotEqual(
            Notifier.weeklyDigestID(forWeek: "2026-W39"),
            Notifier.weeklyDigestID(forWeek: "2026-W40"))
        // 点击路由:带周键的派生 id 与旧版裸键(升级前已发出的)都回总览
        XCTAssertEqual(
            Notifier.openTarget(
                identifier: Notifier.weeklyDigestID(forWeek: "2026-W39"),
                actionIdentifier: UNNotificationDefaultActionIdentifier),
            .dashboard)
        // 前缀必须是完整基键,相近键不误路由
        XCTAssertNil(Notifier.openTarget(
            identifier: "weekly.digestx.2026-W39",
            actionIdentifier: UNNotificationDefaultActionIdentifier))
    }

    func testThreadIdentifierGroupsNotificationFamilies() {
        // 周报一组:裸键与按周派生键同组(通知中心折叠成一条堆叠)
        XCTAssertEqual(Notifier.threadIdentifier(for: Notifier.weeklyDigestID), "weekly.digest")
        XCTAssertEqual(
            Notifier.threadIdentifier(for: Notifier.weeklyDigestID(forWeek: "2026-W39")),
            "weekly.digest")
        // 配额/用量/余额告警一组
        XCTAssertEqual(Notifier.threadIdentifier(for: "codex.quota.low"), "quota.alert")
        XCTAssertEqual(Notifier.threadIdentifier(for: "claude.daily.over"), "quota.alert")
        XCTAssertEqual(Notifier.threadIdentifier(for: "deepseek.balance.low"), "quota.alert")
        XCTAssertEqual(Notifier.threadIdentifier(for: "zhipu.quota.low"), "quota.alert")
        // 节奏预警自成一组(key 带窗口重置时刻,前缀匹配)
        XCTAssertEqual(
            Notifier.threadIdentifier(for: "quota.pace.codex-weekly@1723"),
            "quota.pace")
        // 未知键自成一组(用 id 本身),绝不与已知组混叠
        XCTAssertEqual(Notifier.threadIdentifier(for: "update.available"), "update.available")
    }

    func testAlertSamplesAllRouteSomewhere() {
        // 每个样例的 id 都在跳转路由里(点横幅必有落点),派生动作不跳;
        // 第 8 条为周报样例(按所述周派生 id),一次验证留痕+分组+跳转
        let samples = Notifier.alertSamples()
        XCTAssertEqual(samples.count, 8)
        for sample in samples {
            XCTAssertNotNil(Notifier.openTarget(
                identifier: sample.id,
                actionIdentifier: UNNotificationDefaultActionIdentifier),
                "样例 \(sample.id) 应有跳转落点")
            XCTAssertNil(Notifier.openTarget(
                identifier: sample.id,
                actionIdentifier: UNNotificationDismissActionIdentifier))
        }
    }

    func testAlertSamplesCoverAllJumpTargets() {
        // 样例覆盖四个来源页落点与总览落点(节奏样例走前缀路由回总览)
        let targets = Notifier.alertSamples().map {
            Notifier.openTarget(
                identifier: $0.id,
                actionIdentifier: UNNotificationDefaultActionIdentifier)
        }
        for expected in [AppView.source(.codex), .source(.claude),
                         .source(.kimi), .source(.deepseek), .dashboard] {
            XCTAssertTrue(targets.contains(expected), "样例应覆盖落点 \(expected)")
        }
        // 样例文案明示是预览,不与真实告警混淆
        for sample in Notifier.alertSamples() {
            XCTAssertTrue(sample.body.hasPrefix("【样例】"))
        }
        // 推样例同时能验证分组:六种告警落告警组、节奏样例落节奏组、
        // 周报样例落周报组(按所述周派生的 id 仍归 weekly.digest 组)
        let threads = Set(Notifier.alertSamples().map {
            Notifier.threadIdentifier(for: $0.id)
        })
        XCTAssertEqual(threads, ["quota.alert", "quota.pace", "weekly.digest"])
    }
}
