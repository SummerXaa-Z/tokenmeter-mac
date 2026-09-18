import XCTest
@testable import TokenMeter

final class SubscriptionQuotaSnapshotTests: XCTestCase {
    func testCombinesSourcesInStableOrderAndUsesStableGroupIDs() throws {
        let codex = CodexRateLimits(
            limitId: "codex",
            limitName: nil,
            primary: CodexRateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 2_000_000_000)
            ),
            secondary: nil,
            planType: "pro",
            asOf: Date()
        )
        let kimi = KimiQuotaResult(
            summary: KimiQuotaRow(
                name: "Weekly",
                window: KimiQuotaWindow(duration: 1, unit: .week),
                used: 20,
                limit: 100,
                resetAt: nil
            ),
            limits: [],
            extraUsage: nil
        )
        let ark = try arkSnapshot(#"""
        [
          {"product":"coding-plan","subscribed":true,"periods":[]},
          {"product":"agent-plan","subscribed":true,"periods":[]}
        ]
        """#)
        let zhipu = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(
                usedPercent: 25,
                used: 10_261_098,
                total: 40_000_000,
                resetAt: Date(timeIntervalSince1970: 1_767_373_239.187)
            ),
            weekly: nil
        )

        let snapshot = SubscriptionQuotaSnapshot(codex: codex, kimi: kimi, ark: ark, zhipu: zhipu)

        XCTAssertEqual(snapshot.groups.map(\.id), [
            "codex:subscription",
            "kimi-code:subscription",
            "ark:agent-plan",
            "ark:coding-plan",
            "zhipu:subscription",
        ])
        XCTAssertEqual(
            snapshot.groups.map(\.source),
            [.codex, .kimiCode, .ark, .ark, .zhipu]
        )
    }

    func testCodexMapsOnlyMainChannelWithCanonicalLabelsAndClampedRemaining() {
        let primaryReset = Date(timeIntervalSince1970: 2_000_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 2_000_100_000)
        let main = CodexRateLimits(
            limitId: "codex",
            limitName: nil,
            primary: CodexRateWindow(
                usedPercent: -20,
                windowMinutes: 300,
                resetsAt: primaryReset
            ),
            secondary: CodexRateWindow(
                usedPercent: 125,
                windowMinutes: 10_080,
                resetsAt: secondaryReset
            ),
            planType: "pro",
            asOf: Date()
        )

        let group = SubscriptionQuotaSnapshot(codex: main).groups[0]

        XCTAssertEqual(group.id, "codex:subscription")
        XCTAssertEqual(group.subtitle, "PRO")
        XCTAssertEqual(group.periods.map(\.id), [
            "codex:subscription:primary",
            "codex:subscription:secondary",
        ])
        XCTAssertEqual(group.periods.map(\.label), ["5小时", "周"])
        XCTAssertEqual(group.periods.map(\.remainingPercent), [100, 0])
        XCTAssertEqual(group.periods.map(\.resetAt), [primaryReset, secondaryReset])

        let experimental = CodexRateLimits(
            limitId: "codex_spark",
            limitName: "Spark",
            primary: main.primary,
            secondary: nil,
            planType: "pro",
            asOf: Date()
        )
        XCTAssertEqual(SubscriptionQuotaSnapshot(codex: experimental).groups, [])
    }

    func testKimiMapsSummaryAndSortedLimitsAndPreservesExtraUsage() throws {
        let extra = KimiQuotaExtraUsage(
            balanceCents: 500,
            totalCents: 1_000,
            monthlyChargeLimitEnabled: true,
            monthlyChargeLimitCents: 2_000,
            monthlyUsedCents: 1_500,
            currency: "CNY"
        )
        let kimi = KimiQuotaResult(
            summary: KimiQuotaRow(
                name: "Weekly",
                window: KimiQuotaWindow(duration: 1, unit: .week),
                used: 40,
                limit: 1_000,
                resetAt: "2030-01-01T00:00:00.000Z"
            ),
            // 故意逆序，归一层仍按窗口键稳定排序。
            limits: [
                KimiQuotaRow(
                    name: "Weekly detail",
                    window: KimiQuotaWindow(duration: 1, unit: .week),
                    used: 50,
                    limit: 100,
                    resetAt: nil
                ),
                KimiQuotaRow(
                    name: "Five hour",
                    window: KimiQuotaWindow(duration: 5, unit: .hour),
                    used: 1,
                    limit: 100,
                    resetAt: "2030-01-01T01:02:03.456Z"
                ),
            ],
            extraUsage: extra,
            origin: .officialAPI
        )

        let group = SubscriptionQuotaSnapshot(kimi: kimi).groups[0]

        XCTAssertEqual(group.subtitle, "KIMI API")
        XCTAssertEqual(group.periods.map(\.label), ["5小时", "周", "周"])
        XCTAssertEqual(group.periods.map(\.remainingPercent), [99, 50, 96])
        XCTAssertEqual(group.periods.map(\.id), [
            "kimi-code:subscription:limit:hour-5:0",
            "kimi-code:subscription:limit:week-1:0",
            "kimi-code:subscription:summary",
        ])
        XCTAssertNotNil(group.periods[0].resetAt)
        XCTAssertNotNil(group.periods[2].resetAt)
        XCTAssertNil(group.periods[0].detail)
        XCTAssertEqual(group.extraUsage, SubscriptionQuotaExtraUsage(
            balanceCents: 500,
            totalCents: 1_000,
            monthlyChargeLimitEnabled: true,
            monthlyChargeLimitCents: 2_000,
            monthlyUsedCents: 1_500,
            currency: "CNY"
        ))
    }

    func testArkKeepsSubscribedItemsSortsPeriodsAndMarksAgentPlanAmountsAsAFP() throws {
        let ark = try arkSnapshot(#"""
        [
          {
            "product":"coding-plan",
            "edition":"personal",
            "subscribed":true,
            "periods":[
              {"label":"monthly","percent":30},
              {"label":"session","percent":20},
              {"label":"weekly","percent":10}
            ]
          },
          {
            "product":"agent-plan",
            "edition":"personal",
            "tier":"medium",
            "subscribed":true,
            "periods":[
              {"label":"monthly","used":300,"total":1000,"percent":30},
              {"label":"5h","used":25,"total":100,"percent":25},
              {"label":"weekly","used":100,"total":500,"percent":20}
            ]
          },
          {
            "product":"agent-plan-team",
            "subscribed":false,
            "periods":[]
          }
        ]
        """#)

        let groups = SubscriptionQuotaSnapshot(ark: ark).groups

        XCTAssertEqual(groups.map(\.id), ["ark:agent-plan", "ark:coding-plan"])
        XCTAssertEqual(groups[0].subtitle, "MEDIUM")
        XCTAssertEqual(groups[0].periods.map(\.label), ["5小时", "周", "月"])
        XCTAssertEqual(groups[0].periods.map(\.remainingPercent), [75, 80, 70])
        XCTAssertEqual(groups[0].periods.map(\.detail), [
            "已用 25 / 100 AFP",
            "已用 100 / 500 AFP",
            "已用 300 / 1000 AFP",
        ])
        XCTAssertEqual(groups[1].periods.map(\.label), ["会话", "周", "月"])
        XCTAssertEqual(groups[1].periods.map(\.remainingPercent), [80, 90, 70])
        XCTAssertTrue(groups.flatMap(\.periods).map(\.id).allSatisfy { !$0.isEmpty })
    }

    func testParsesISO8601OffsetAndFractionalResetDates() throws {
        let ark = try arkSnapshot(#"""
        [
          {
            "product":"agent-plan",
            "subscribed":true,
            "periods":[
              {
                "label":"5h",
                "percent":25,
                "reset_at":"2026-08-13T05:26:40+08:00"
              }
            ]
          }
        ]
        """#)
        let kimi = KimiQuotaResult(
            summary: KimiQuotaRow(
                name: nil,
                window: KimiQuotaWindow(duration: 1, unit: .week),
                used: 0,
                limit: 100,
                resetAt: "2030-01-01T01:02:03.456Z"
            ),
            limits: [],
            extraUsage: nil
        )

        let snapshot = SubscriptionQuotaSnapshot(kimi: kimi, ark: ark)
        let kimiReset = try XCTUnwrap(snapshot.groups[0].periods[0].resetAt)
        let arkReset = try XCTUnwrap(snapshot.groups[1].periods[0].resetAt)
        let calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(
            calendar.dateComponents(in: utc, from: arkReset).year,
            2026
        )
        XCTAssertEqual(calendar.dateComponents(in: utc, from: arkReset).hour, 21)
        XCTAssertEqual(calendar.dateComponents(in: utc, from: arkReset).minute, 26)
        XCTAssertEqual(calendar.dateComponents(in: utc, from: kimiReset).second, 3)
        XCTAssertEqual(
            kimiReset.timeIntervalSince1970.rounded(.down),
            kimiReset.timeIntervalSince1970 - 0.456,
            accuracy: 0.001
        )
    }

    func testNilSourcesProduceEmptySnapshot() {
        XCTAssertEqual(SubscriptionQuotaSnapshot().groups, [])
    }

    func testZhipuMapsWindowsLevelAndDetails() {
        let fiveHourReset = Date(timeIntervalSince1970: 1_767_373_239.187)
        let weeklyReset = Date(timeIntervalSince1970: 1_767_632_400)
        let result = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(
                usedPercent: 25,
                used: 10_261_098,
                total: 40_000_000,
                resetAt: fiveHourReset
            ),
            weekly: ZhipuQuotaTier(
                usedPercent: 44,
                used: 53_000_000,
                total: 120_000_000,
                resetAt: weeklyReset
            ),
            toolCalls: ZhipuQuotaTier(
                usedPercent: 72,
                used: 72,
                total: 100,
                resetAt: nil
            ),
            level: "pro"
        )

        let group = SubscriptionQuotaSnapshot(zhipu: result).groups[0]

        XCTAssertEqual(group.id, "zhipu:subscription")
        XCTAssertEqual(group.source, .zhipu)
        XCTAssertEqual(group.title, "智谱 GLM")
        XCTAssertEqual(group.subtitle, "PRO")
        XCTAssertEqual(group.periods.map(\.id), [
            "zhipu:subscription:five-hour",
            "zhipu:subscription:weekly",
            "zhipu:subscription:tool-calls",
        ])
        XCTAssertEqual(group.periods.map(\.label), ["5小时", "每周", "工具调用"])
        XCTAssertEqual(group.periods.map(\.remainingPercent), [75, 56, 28])
        XCTAssertEqual(group.periods.map(\.resetAt), [fiveHourReset, weeklyReset, nil])
        XCTAssertEqual(group.periods[0].detail, "已用 10.3M / 40.0M")
        XCTAssertEqual(group.periods[1].detail, "已用 53.0M / 120M")
        XCTAssertEqual(group.periods[2].detail, "已用 72 / 100 次")
    }

    func testZhipuClampsRemainingPercentAndOmitsMissingWindows() {
        let result = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(
                usedPercent: 130,
                used: nil,
                total: nil,
                resetAt: nil
            ),
            weekly: nil,
            toolCalls: nil,
            level: "  "
        )

        let group = SubscriptionQuotaSnapshot(zhipu: result).groups[0]

        XCTAssertEqual(group.periods.map(\.id), ["zhipu:subscription:five-hour"])
        XCTAssertEqual(group.periods[0].remainingPercent, 0)
        XCTAssertNil(group.periods[0].detail)
        XCTAssertNil(group.subtitle)
    }

    private func arkSnapshot(_ json: String) throws -> ArkPlanQuotaSnapshot {
        ArkPlanQuotaSnapshot(
            items: try ArkPlanQuotaService.parseItems(Data(json.utf8)),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}
