import AppKit

// 手动入口：菜单栏应用用 AppDelegate 驱动，不用 SwiftUI App 生命周期。
// top-level code 在主线程执行，用 assumeIsolated 进入 MainActor 上下文，
// 以便构造 @MainActor 隔离的 AppDelegate。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
