import Foundation
import XCTest
@testable import TokenMeter

final class LoginSyncOriginTests: XCTestCase {
    func testAcceptsOnlyHTTPSPlatformDeepSeekMainFrame() {
        XCTAssertTrue(LoginSyncController.acceptsTokenMessage(protocol: "https", host: "platform.deepseek.com", port: 443, isMainFrame: true))
        XCTAssertTrue(LoginSyncController.acceptsTokenMessage(protocol: "https", host: "platform.deepseek.com", port: 0, isMainFrame: true))
        XCTAssertFalse(LoginSyncController.acceptsTokenMessage(protocol: "http", host: "platform.deepseek.com", port: 80, isMainFrame: true))
        XCTAssertFalse(LoginSyncController.acceptsTokenMessage(protocol: "https", host: "platform.deepseek.com", port: 443, isMainFrame: false))
        XCTAssertFalse(LoginSyncController.acceptsTokenMessage(protocol: "https", host: "platform.deepseek.com.evil.example", port: 443, isMainFrame: true))
        XCTAssertFalse(LoginSyncController.acceptsTokenMessage(protocol: "https", host: "another.deepseek.com", port: 443, isMainFrame: true))
        XCTAssertFalse(LoginSyncController.acceptsTokenMessage(protocol: "https", host: "platform.deepseek.com", port: 8443, isMainFrame: true))
    }

    func testNavigationRejectsUnapprovedHostSchemePortAndPopup() throws {
        for text in ["http://platform.deepseek.com", "https://platform.deepseek.com:8443", "https://evil.example", "file:///tmp/fixture", "https://api.deepseek.com"] {
            XCTAssertFalse(LoginSyncController.allowsNavigation(to: try XCTUnwrap(URL(string: text)), hasTargetFrame: true))
        }
        let allowed = try XCTUnwrap(URL(string: "https://platform.deepseek.com/sign_in"))
        XCTAssertTrue(LoginSyncController.allowsNavigation(to: allowed, hasTargetFrame: true))
        XCTAssertFalse(LoginSyncController.allowsNavigation(to: allowed, hasTargetFrame: false))
    }
}
