import AppKit
import WebKit

// 打开 DeepSeek 开放平台的独立窗口。
// 用 WKWebView 默认持久 data store，与登录同步窗口共享 cookie——
// 只要通过「网页登录自动同步」登录过，这里打开即是已登录状态。
@MainActor
final class PlatformPortal: NSObject {
    static let shared = PlatformPortal()

    private var window: NSWindow?
    private var webView: WKWebView?

    private static let platformURL = URL(string: "https://platform.deepseek.com")!

    func open() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760),
                           configuration: WKWebViewConfiguration())
        wv.customUserAgent = DeepSeekAPI.macUA
        wv.load(URLRequest(url: Self.platformURL))
        webView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "DeepSeek 开放平台"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

extension PlatformPortal: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
    }
}
