import XCTest
@testable import TokenMeter

final class ArkPlanQuotaServiceTests: XCTestCase {
    func testParsesAgentPlanAndPreservesQuotaFields() throws {
        let data = Data(#"""
        [
          {
            "product": "agent-plan",
            "edition": "personal",
            "tier": "medium",
            "subscribed": true,
            "periods": [
              {
                "label": "5h",
                "used": 250,
                "total": 1000,
                "percent": 25,
                "reset_at": "2026-08-13T05:26:40+08:00"
              }
            ]
          }
        ]
        """#.utf8)

        let items = try ArkPlanQuotaService.parseItems(data)
        let item = try XCTUnwrap(items.first)
        let period = try XCTUnwrap(item.periods.first)

        XCTAssertEqual(item.product, "agent-plan")
        XCTAssertEqual(item.edition, "personal")
        XCTAssertEqual(item.tier, "medium")
        XCTAssertTrue(item.subscribed)
        XCTAssertEqual(period.used, 250)
        XCTAssertEqual(period.total, 1_000)
        XCTAssertEqual(period.percent, 25)
        XCTAssertEqual(period.remainingPercent, 75)
        XCTAssertEqual(period.remainingAmount, 750)
        XCTAssertEqual(period.resetAt, "2026-08-13T05:26:40+08:00")
    }

    func testCodingPlanCanOmitAbsoluteAmountsAndFailedBucketDoesNotBreakResponse() throws {
        let data = Data(#"""
        [
          {
            "product": "coding-plan",
            "edition": "personal",
            "subscribed": true,
            "periods": [
              { "label": "weekly", "percent": 62.5 }
            ]
          },
          {
            "product": "agent-plan-team",
            "edition": "team",
            "subscribed": true,
            "error": "no seat bound to caller"
          }
        ]
        """#.utf8)

        let items = try ArkPlanQuotaService.parseItems(data)

        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0].periods[0].used)
        XCTAssertNil(items[0].periods[0].total)
        XCTAssertEqual(items[0].periods[0].remainingPercent, 37.5)
        XCTAssertEqual(items[1].periods, [])
        XCTAssertEqual(items[1].error, "no seat bound to caller")
    }

    func testRemainingPercentIsClamped() throws {
        let data = Data(#"""
        [
          {
            "product": "agent-plan",
            "subscribed": true,
            "periods": [
              { "label": "over", "percent": 125 },
              { "label": "negative", "percent": -10 }
            ]
          }
        ]
        """#.utf8)

        let periods = try ArkPlanQuotaService.parseItems(data)[0].periods

        XCTAssertEqual(periods[0].remainingPercent, 0)
        XCTAssertEqual(periods[1].remainingPercent, 100)
    }

    func testLoadUsesPrivacyPreservingCommandsAndFifteenSecondTimeout() async throws {
        let runner = StubArkPlanRunner(responses: [
            Data("true".utf8),
            Data(#"[{"product":"agent-plan","subscribed":true,"periods":[]}]"#.utf8),
        ])

        let snapshot = try await ArkPlanQuotaService.load(runner: runner)
        let calls = await runner.recordedCalls()

        XCTAssertEqual(snapshot.items.map(\.product), ["agent-plan"])
        XCTAssertEqual(calls, [
            .init(arguments: ArkPlanQuotaService.authArguments, timeout: 15),
            .init(arguments: ArkPlanQuotaService.planArguments, timeout: 15),
        ])
        XCTAssertEqual(
            ArkPlanQuotaService.authArguments,
            ["auth", "status", "--format", "json", "--transform", "logged_in"]
        )
        XCTAssertEqual(
            ArkPlanQuotaService.planArguments,
            ["usage", "plan", "--format", "json", "--transform", "items"]
        )
    }

    func testLoggedOutStopsBeforePlanQuery() async throws {
        let runner = StubArkPlanRunner(responses: [Data("false".utf8)])

        do {
            _ = try await ArkPlanQuotaService.load(runner: runner)
            XCTFail("Expected notLoggedIn")
        } catch {
            XCTAssertEqual(error as? ArkPlanQuotaError, .notLoggedIn)
        }

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.map(\.arguments), [ArkPlanQuotaService.authArguments])
    }

    func testMalformedOutputReturnsGenericDecodeError() {
        let privateOutput = Data("private-account-data".utf8)

        XCTAssertThrowsError(try ArkPlanQuotaService.parseItems(privateOutput)) { error in
            let quotaError = error as? ArkPlanQuotaError
            XCTAssertEqual(quotaError, .decodeFailed)
            XCTAssertFalse(quotaError?.errorDescription?.contains("private-account-data") == true)
        }
    }

    func testSanitizedEnvironmentHasRequiredPathAndDropsArkSecrets() {
        let home = URL(fileURLWithPath: "/Users/example")
        let environment = ArkCLIProcessRunner.sanitizedEnvironment(
            processEnvironment: [
                "HOME": "/wrong",
                "USER": "example",
                "ARK_API_KEY": "must-not-pass",
                "PATH": "/untrusted/bin",
            ],
            home: home
        )

        XCTAssertEqual(
            environment["PATH"],
            "/Users/example/.npm-global/bin:/Users/example/.homebrew/bin:"
                + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        )
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertNil(environment["ARK_API_KEY"])
        XCTAssertFalse(environment["PATH"]?.contains("/untrusted/bin") == true)
    }

    func testProcessRunnerEnforcesOutputLimitWithoutReturningOutput() {
        let privateOutput = String(repeating: "secret", count: 100)

        XCTAssertThrowsError(try ArkCLIProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [privateOutput],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 2,
            maximumStdoutBytes: 32,
            maximumStderrBytes: 32
        )) { error in
            let quotaError = error as? ArkPlanQuotaError
            XCTAssertEqual(quotaError, .outputTooLarge)
            XCTAssertFalse(quotaError?.errorDescription?.contains(privateOutput) == true)
        }
    }

    func testProcessRunnerEnforcesHardTimeout() {
        let startedAt = Date()

        XCTAssertThrowsError(try ArkCLIProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 0.05,
            maximumStdoutBytes: 32,
            maximumStderrBytes: 32
        )) { error in
            XCTAssertEqual(error as? ArkPlanQuotaError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }
}

private actor StubArkPlanRunner: ArkPlanQuotaCommandRunning {
    struct Call: Equatable, Sendable {
        let arguments: [String]
        let timeout: TimeInterval
    }

    private let responses: [Data]
    private var responseIndex = 0
    private var calls: [Call] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> Data {
        calls.append(Call(arguments: arguments, timeout: timeout))
        guard responses.indices.contains(responseIndex) else {
            throw ArkPlanQuotaError.commandFailed(code: 99)
        }
        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    func recordedCalls() -> [Call] {
        calls
    }
}
