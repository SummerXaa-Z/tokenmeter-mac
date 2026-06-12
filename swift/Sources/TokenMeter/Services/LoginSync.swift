import AppKit
import WebKit
import Combine

// 网页登录自动同步：弹一个 WKWebView 打开 DeepSeek 平台登录页，
// 注入 JS hook fetch/XHR，从平台 API 请求的 Authorization 头抓 Bearer token。
// 相比 Tauri 版的 document.title hack，WKScriptMessageHandler 直接回原生，更干净。
@MainActor
final class LoginSyncController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    // captured: 抓到并验证通过的 token；ended: 窗口关闭但未捕获
    @Published var captured: String?
    @Published var ended = false

    private var window: NSWindow?
    private var webView: WKWebView?
    private var done = false

    private static let loginURL = URL(string: "https://platform.deepseek.com")!

    // 注入脚本：hook fetch 与 XHR 的 Authorization 头
    private static let hookJS = """
    (function() {
      if (window.__dsm_hook__) return;
      window.__dsm_hook__ = true;
      function deliver(token) {
        if (!token || typeof token !== 'string') return;
        token = token.trim();
        if (token.length < 20) return;
        try {
          window.webkit.messageHandlers.dsmToken.postMessage(token);
        } catch (e) {}
      }
      function fromAuth(value) {
        if (!value) return;
        var m = /Bearer\\s+(\\S+)/i.exec(String(value));
        if (m && m[1]) deliver(m[1]);
      }
      var of = window.fetch;
      if (typeof of === 'function') {
        window.fetch = function(input, init) {
          try {
            var h = (init && init.headers) || (input && input.headers);
            if (h) {
              if (typeof Headers !== 'undefined' && h instanceof Headers) {
                fromAuth(h.get('authorization'));
              } else if (Array.isArray(h)) {
                for (var i = 0; i < h.length; i++) {
                  if (h[i] && String(h[i][0]).toLowerCase() === 'authorization') fromAuth(h[i][1]);
                }
              } else if (typeof h === 'object') {
                for (var k in h) { if (k.toLowerCase() === 'authorization') fromAuth(h[k]); }
              }
            }
          } catch (e) {}
          return of.apply(this, arguments);
        };
      }
      var os = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        try { if (name && String(name).toLowerCase() === 'authorization') fromAuth(value); } catch (e) {}
        return os.apply(this, arguments);
      };
    })();
    """

    // 返回 true 表示已直接命中（本实现总是打开窗口异步捕获，返回 false）
    func start() -> Bool {
        done = false
        ended = false
        captured = nil
        if window != nil {
            webView?.reload()
            return false
        }

        let cfg = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "dsmToken")
        let script = WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        controller.addUserScript(script)
        cfg.userContentController = controller

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = DeepSeekAPI.macUA
        wv.load(URLRequest(url: Self.loginURL))
        webView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "DeepSeek 账号登录"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        return false
    }

    // 收到注入脚本回传的 token
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !done, let token = message.body as? String else { return }
        let cal = Calendar.current
        let now = Date()
        let month = cal.component(.month, from: now)
        let year = cal.component(.year, from: now)
        Task {
            // 验证 token 真能调用用量接口，过滤登录中途的临时 token
            guard await DeepSeekAPI.verifyUsageToken(token, month: month, year: year) else { return }
            await MainActor.run {
                guard !self.done else { return }
                self.done = true
                ConfigStore.shared.credUsageToken = token
                self.captured = token
                self.closeWindow()
            }
        }
    }

    private func closeWindow() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dsmToken")
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }
}

extension LoginSyncController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
        if !done {
            ended = true
        }
    }
}
