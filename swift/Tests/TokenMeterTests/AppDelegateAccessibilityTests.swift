import AppKit
import SwiftUI
import XCTest
@testable import TokenMeter

final class AppDelegateAccessibilityTests: XCTestCase {
    @MainActor
    func testStatusButtonHasStableAccessibilityMetadata() throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }

        let button = try XCTUnwrap(item.button)
        AppDelegate.configureStatusButton(button)

        XCTAssertEqual(button.toolTip, "TokenMeter")
        XCTAssertEqual(button.accessibilityLabel(), "TokenMeter")
        XCTAssertEqual(button.accessibilityHelp(), "打开 TokenMeter 用量面板")
        XCTAssertEqual(button.accessibilityIdentifier(), "TokenMeter.StatusItem")
        XCTAssertEqual(button.image?.isTemplate, true)
    }
}

#if DEBUG
final class RenderViewportTests: XCTestCase {
    @MainActor
    func testOversizedContentCannotResizeFixtureWindow() async throws {
        let expected = NSSize(width: Theme.panelWidth, height: 600)
        let host = DebugUIRenderHarness.makeViewportHost(
            Color.red.frame(minWidth: 900, minHeight: 800), height: expected.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: expected),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.size, expected)
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, expected)
        }
    }
}
#endif
