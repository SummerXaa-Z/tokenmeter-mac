import XCTest
@testable import TokenMeter

final class DiagnosticReportTests: XCTestCase {
    func testBuildRedactsSensitiveFragmentsAndShortensHomePaths() {
        let context = DiagnosticReport.Context(
            generatedAt: Date(timeIntervalSince1970: 1_720_000_000),
            appVersion: "3.7.1",
            bundleIdentifier: "com.deepseek.monitor.mac",
            bundlePath: "/Users/summer/Applications/TokenMeter.app",
            signatureStatus: "valid",
            macOSVersion: "macOS 15.5",
            architecture: "arm64",
            updateStatus: "failed: Authorization: Bearer secret-token",
            sources: [
                DiagnosticReport.SourceStatus(
                    name: "Claude",
                    enabled: true,
                    available: true,
                    running: "运行中",
                    path: "/Users/summer/.claude/projects",
                    detail: "token=sk-secret cookie=cookie-value-123"
                ),
                DiagnosticReport.SourceStatus(
                    name: "Codex",
                    enabled: true,
                    available: false,
                    running: "未运行",
                    path: "/Users/summer/.codex/sessions",
                    detail: nil
                )
            ]
        )

        let text = DiagnosticReport.build(context: context, homePath: "/Users/summer")

        XCTAssertTrue(text.contains("TokenMeter Diagnostic Report"))
        XCTAssertTrue(text.contains("Version: 3.7.1"))
        XCTAssertTrue(text.contains("Bundle ID: com.deepseek.monitor.mac"))
        XCTAssertTrue(text.contains("Path: ~/Applications/TokenMeter.app"))
        XCTAssertTrue(text.contains("Claude: enabled=yes available=yes running=运行中 path=~/.claude/projects"))
        XCTAssertTrue(text.contains("Codex: enabled=yes available=no running=未运行 path=~/.codex/sessions"))
        XCTAssertFalse(text.contains("/Users/summer"))
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertFalse(text.contains("sk-secret"))
        XCTAssertFalse(text.contains("cookie-value-123"))
        XCTAssertTrue(text.contains("<redacted>"))
    }

    func testDefaultFilenameIncludesVersionAndTxtExtension() {
        XCTAssertEqual(
            DiagnosticReport.defaultFilename(version: "3.7.1"),
            "TokenMeter-Diagnostics-3.7.1.txt"
        )
    }
}
