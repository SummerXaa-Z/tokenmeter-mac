import AppKit
import SwiftUI
import XCTest
@testable import TokenMeter

final class ModelDetailInteractionTests: XCTestCase {
    @MainActor
    func testRangeControlRecoversFromEmptyStateAndCanReturnToIt() async throws {
        XCTAssertTrue(RuntimeEnvironment.isIsolated)
        let state = AppState()
        let reader = HistorySnapshotReader(initial: .init(), read: { .init() })
        let content = CodingModelDetailView(
            source: .codex, model: "gpt-5.4", onBack: {},
            injectedFor: { days in
                CodingModelDetail.summary(
                    source: .codex, model: "gpt-5.4",
                    liveDayModels: ["2026-09-22": ["gpt-5.4": .init(input: 2_000_000)]],
                    todayKey: "2026-11-01", windowDays: days, allHistory: days == 0)
            }, initialRange: .month)
            .environmentObject(state)
            .environmentObject(reader)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        try await waitForText("近 30 天暂无该模型明细", in: host)
        try pressRange("90D", in: host)
        try await waitForText("近 90 天 Token", in: host)
        XCTAssertFalse(texts(in: host).contains("近 30 天暂无该模型明细"))
        XCTAssertTrue(texts(in: host).contains(Fmt.tokensShort(2_000_000)))

        try pressRange("30D", in: host)
        try await waitForText("近 30 天暂无该模型明细", in: host)
        XCTAssertFalse(texts(in: host).contains(Fmt.tokensShort(2_000_000)))
        try pressRange("90D", in: host)
        try await waitForText("近 90 天 Token", in: host)
        XCTAssertTrue(texts(in: host).contains(Fmt.tokensShort(2_000_000)))
    }

    @MainActor
    private func elements(in root: Any) -> [any NSAccessibility] {
        guard let element = root as? any NSAccessibility else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { elements(in: $0) }
    }

    @MainActor
    private func texts(in host: NSView) -> [String] {
        elements(in: host).flatMap { element in
            [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }
        }
    }

    @MainActor
    private func pressRange(_ title: String, in host: NSView) throws {
        let control = try XCTUnwrap(elements(in: host).first {
            $0.accessibilityLabel() == title && $0.accessibilityRole() == .radioButton
        }, "Missing range control \(title): \(texts(in: host))")
        XCTAssertTrue(control.accessibilityPerformPress(), "Range control rejected press: \(title)")
    }

    @MainActor
    private func waitForText(_ text: String, in host: NSView) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if texts(in: host).contains(text) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Missing rendered text \(text): \(texts(in: host))")
    }
}
