import AppKit
import SwiftUI

// 菜单栏外壳：状态栏图标 + NSPopover 承载 SwiftUI。
// 这是原生 macOS 菜单栏应用的标准做法——面板贴着状态栏图标下拉、带小箭头。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
#if DEBUG
    private var smokeWindow: NSWindow?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        // 菜单栏 popover 很难被 UI 自动化稳定定位。这个显式启动参数只在
        // Debug 构建提供同尺寸普通窗口，跳过通知、更新器和后台计时器；
        // 正常启动与 Release 构建完全不受影响。
        if ProcessInfo.processInfo.arguments.contains("--ui-smoke-window") {
            showUISmokeWindow()
            return
        }
        // 离屏渲染真实视图树为 PNG 供设计审查：无需录屏权限，进程内导出。
        if let renderArg = ProcessInfo.processInfo.arguments.first(
            where: { $0.hasPrefix("--ui-render=") })
        {
            runUIRender(outputPath: String(renderArg.dropFirst("--ui-render=".count)))
            return
        }
#endif
        // 菜单栏应用：不占 Dock、不抢主菜单栏
        NSApp.setActivationPolicy(.accessory)

        // SwiftUI 根视图塞进 popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 600)
        popover.behavior = .transient   // 点外部自动收起
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(appState))

        // 状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            Self.configureStatusButton(button)
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        appState.rearmTimer()

        // 仅在用户开启通知时申请权限；关闭状态重启不能再次打扰用户。
        Notifier.requestAuthorizationIfEnabled(ConfigStore.shared.notificationsEnabled)

        // 启动 5s 后做每日一次的更新检查（静默，仅有新版时弹窗）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.shared.autoCheckIfDue()
        }

        // 配额/用量预警 + 菜单栏信息文字，统一 15 分钟刷新
        requestQuotaBadgeRefresh()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestQuotaBadgeRefresh() }
        }
        // 设置或余额状态变化后立刻生效，不等 15 分钟定时周期
        NotificationCenter.default.addObserver(forName: .statusRefreshRequested, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestQuotaBadgeRefresh() }
        }
    }

    private var quotaTimer: Timer?

#if DEBUG
    private func showUISmokeWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TokenMeter UI Smoke"
        window.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(appState)
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        smokeWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // 用法：TokenMeter --ui-render=<dir>。为每个页面在亮/暗两种外观下
    // 生成 <page>-<appearance>.png 后退出。窗口放在屏幕外，用户无感。
    private func runUIRender(outputPath: String) {
        NSApp.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func hosting<V: View>(_ view: V, height: CGFloat = Theme.panelHeight) -> NSView {
            // cacheDisplay 只渲染视图树本身，页面不自带底色（真实 app 里由
            // popover 窗口背景提供），离屏导出必须在这里补上等价底色。
            let host = NSHostingView(rootView: view
                .background(Color(nsColor: .windowBackgroundColor))
                .environmentObject(appState))
            host.setFrameSize(NSSize(width: Theme.panelWidth, height: height))
            return host
        }

        let pages: [(name: String, view: NSView)] = [
            ("overview", hosting(RootView())),
            ("dashboard", hosting(
                DashboardView(onBack: {}, onSettings: {}, onDetail: { _ in }))),
            ("claude", hosting(ClaudeView(onBack: {}, onSettings: {}))),
            ("codex", hosting(CodexView(onBack: {}, onSettings: {}))),
            ("kimi", hosting(KimiView(onBack: {}, onSettings: {}))),
            ("qwen", hosting(QwenCodeView(onBack: {}, onSettings: {}))),
            ("cursor", hosting(CursorView(onBack: {}, onSettings: {}))),
            ("settings", hosting(SettingsView(onBack: {}))),
            // 长滚动页审计：整页高度导出设置页，覆盖首屏之外的滚动区
            ("settings-full", hosting(SettingsView(onBack: {}), height: 3200)),
        ]

        var windows: [NSWindow] = []
        for page in pages {
            let bounds = page.view.bounds
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: bounds.width, height: bounds.height),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = page.view
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            windows.append(window)
        }

        for appearance in [(name: "light", ns: NSAppearance(named: .aqua)),
                           (name: "dark", ns: NSAppearance(named: .darkAqua))]
        {
            NSApp.appearance = appearance.ns
            // 等本地数据加载与图表布局稳定
            let deadline = Date().addingTimeInterval(3.5)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            for page in pages {
                page.view.layoutSubtreeIfNeeded()
                guard
                    let rep = page.view.bitmapImageRepForCachingDisplay(in: page.view.bounds)
                else { continue }
                page.view.cacheDisplay(in: page.view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(
                        to: dir.appendingPathComponent("\(page.name)-\(appearance.name).png"))
                }
            }
        }
        exit(0)
    }
#endif

    private var alertLatch = AlertLatch()
    private var statusRefreshCoalescer = StatusRefreshCoalescer()

    // 根据"当前是否越线"决定推/撤。crossed=true 且未推过 → 推；crossed=false → 清除记录
    private func evaluateAlert(key: String, crossed: Bool, title: String, body: String) {
        if alertLatch.shouldFire(
            key: key,
            crossed: crossed,
            enabled: ConfigStore.shared.notificationsEnabled
        ) {
            Notifier.send(id: key, title: title, body: body)
        }
    }

    // 统一告警等级：Codex 配额和 Claude 日用量两路各算一个等级，取最高着色，
    // 避免两路各自抢图标颜色互相覆盖
    private enum AlertLevel: Int, Comparable {
        case normal = 0, warn = 1, critical = 2

        static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool { lhs.rawValue < rhs.rawValue }

        var tint: NSColor? {
            switch self {
            case .normal: return nil
            case .warn: return .systemOrange
            case .critical: return .systemRed
            }
        }
    }

    private func requestQuotaBadgeRefresh() {
        guard statusRefreshCoalescer.request() else { return }
        performQuotaBadgeRefresh()
    }

    private func finishQuotaBadgeRefresh() {
        if statusRefreshCoalescer.finish() {
            performQuotaBadgeRefresh()
        }
    }

    // 后台扫一次 Codex 配额 + Claude 今日用量：告警等级给图标着色，
    // 同时按设置把核心指标（Claude 今日 token / Codex 配额剩余）写到图标旁。
    private func performQuotaBadgeRefresh() {
        // 开关与阈值在主线程一次性快照，detached 任务里不再碰共享状态
        let settings = currentStatusRefreshSettings()
        let codexOn = settings.codexEnabled && CodexUsage.isAvailable
        let claudeLimitM = settings.claudeDailyLimitM
        let claudeAlertOn = settings.claudeEnabled
            && ClaudeUsage.isAvailable && claudeLimitM > 0
        let infoMode = settings.menubarInfoMode
        let balanceThreshold = settings.deepseekEnabled
            ? settings.deepseekBalanceAlertThreshold : 0
        let claudeUsable = settings.claudeEnabled && ClaudeUsage.isAvailable
        let claudeInfoOn = (infoMode == "claude" || infoMode == "total") && claudeUsable
        let codexQuotaInfoOn = infoMode == "codex" && codexOn
        let codexTotalInfoOn = infoMode == "total" && codexOn

        // 用户明确关闭来源/阈值等同于重新布防；以后重新开启时应允许立即提醒。
        if balanceThreshold <= 0 { alertLatch.reset(key: "deepseek.balance.low") }
        if !codexOn { alertLatch.reset(key: "codex.quota.low") }
        if !claudeAlertOn { alertLatch.reset(key: "claude.daily.over") }

        // 余额预警独立于 detached 扫描：balance 已在 appState（主线程，无 I/O）。
        // 放在 guard 前，避免"只开余额预警"时被提前 return 跳过。
        if balanceThreshold > 0,
           case .ok = appState.balanceState,
           let bal = appState.balance,
           let value = Double(bal.totalBalance) {
            evaluateAlert(
                key: "deepseek.balance.low", crossed: value < Double(balanceThreshold),
                title: "DeepSeek 余额不足",
                body: "当前余额 \(bal.symbol)\(bal.totalBalance)，低于 \(balanceThreshold) 预警线")
        }

        guard codexOn || claudeAlertOn || claudeInfoOn else {
            setStatusIcon(tint: nil, text: nil)
            finishQuotaBadgeRefresh()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                if codexOn {
                    group.addTask { await self.appState.loadCodex() }
                }
                if claudeAlertOn || claudeInfoOn {
                    group.addTask { await self.appState.loadClaude() }
                }
            }

            var level = AlertLevel.normal
            var infoTokens = 0          // total/claude 模式累加今日 token
            var infoText: String?
            // 告警事实在后台算好，回主线程统一过状态机推送
            var codexCrossed: Bool?     // nil = 本轮未评估
            var codexRemaining = 0
            var claudeCrossed: Bool?
            var claudeToday = 0

            if codexOn, let codexResult = self.appState.codex.result {
                // AppState 已把官方实时配额合并进本地用量结果，状态栏复用同一口径。
                let limits = codexResult.rateLimits
                let worstUsed = max(limits?.primary?.usedPercent ?? 0,
                                    limits?.secondary?.usedPercent ?? 0)
                let remaining = 100 - worstUsed
                if codexOn {
                    if remaining <= 10 { level = max(level, .critical) }
                    else if remaining <= 30 { level = max(level, .warn) }
                    // 通知只在 critical 线（≤10%）翻转，且要有真实配额数据
                    if limits != nil {
                        codexCrossed = remaining <= 10
                        codexRemaining = Int(remaining)
                    }
                }
                if codexQuotaInfoOn, limits != nil {
                    infoText = "\(Int(remaining))%"
                }
                if codexTotalInfoOn {
                    infoTokens += codexResult.today?.totalTokens ?? 0
                }
            }

            if claudeAlertOn || claudeInfoOn {
                let todayTokens = self.appState.claude.result?.today?.totalTokens ?? 0
                if claudeAlertOn {
                    let limit = claudeLimitM * 1_000_000
                    // 超阈值即提醒，1.5 倍才升红——日用量越线不等于不可用，留缓冲
                    if todayTokens >= limit * 3 / 2 { level = max(level, .critical) }
                    else if todayTokens >= limit { level = max(level, .warn) }
                    claudeCrossed = todayTokens >= limit
                    claudeToday = todayTokens
                }
                if claudeInfoOn {
                    infoTokens += todayTokens
                }
            }
            if infoText == nil, claudeInfoOn || codexTotalInfoOn {
                infoText = Fmt.tokensShort(infoTokens)
            }

            // 设置变更会另外请求一次合并刷新。旧任务只负责结束并触发补跑，
            // 不能再用旧来源/阈值更新图标或发通知。
            guard settings.isCurrent(self.currentStatusRefreshSettings()) else {
                self.finishQuotaBadgeRefresh()
                return
            }

            self.setStatusIcon(tint: level.tint, text: infoText)
            if let c = codexCrossed {
                self.evaluateAlert(
                        key: "codex.quota.low", crossed: c,
                        title: "Codex 配额告急",
                        body: "订阅配额仅剩 \(codexRemaining)%，留意用量")
            }
            if let c = claudeCrossed {
                self.evaluateAlert(
                        key: "claude.daily.over", crossed: c,
                        title: "Claude 日用量越线",
                        body: "今日已用 \(Fmt.tokensShort(claudeToday))，超过 \(claudeLimitM)M 阈值")
            }
            self.finishQuotaBadgeRefresh()
        }
    }

    private func currentStatusRefreshSettings() -> StatusRefreshSettings {
        let store = ConfigStore.shared
        return StatusRefreshSettings(
            deepseekEnabled: store.deepseekMonitorEnabled,
            deepseekBalanceAlertThreshold: store.deepseekBalanceAlertThreshold,
            claudeEnabled: store.claudeMonitorEnabled,
            claudeDailyLimitM: store.claudeDailyTokenLimitM,
            codexEnabled: store.codexMonitorEnabled,
            menubarInfoMode: store.menubarInfoMode,
            notificationsEnabled: store.notificationsEnabled
        )
    }

    private func setStatusIcon(tint: NSColor?, text: String?) {
        guard let button = statusItem?.button else { return }
        if let tint {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            button.image = Self.statusImage()?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = Self.statusImage()
            button.image?.isTemplate = true
        }
        // 图标旁文字：menubar 字体用 11pt monospaced digit，避免数字跳动
        if let text {
            button.title = " \(text)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // 状态栏图标：用 SF Symbol 生成模板图，缺失则回退到文字
    private static func statusImage() -> NSImage? {
        if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                             accessibilityDescription: "TokenMeter") {
            return img
        }
        return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "TokenMeter")
    }

    static func configureStatusButton(_ button: NSStatusBarButton) {
        button.image = statusImage()
        button.image?.isTemplate = true   // 跟随明暗菜单栏自动反色
        button.toolTip = "TokenMeter"
        button.setAccessibilityLabel("TokenMeter")
        button.setAccessibilityHelp("打开 TokenMeter 用量面板")
        button.setAccessibilityIdentifier("TokenMeter.StatusItem")
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // 右键：弹菜单（显示面板 / 退出）
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            appState.refreshEnabledSources(trigger: .panelOpen)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示主面板", action: #selector(openPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开 DeepSeek 开放平台", action: #selector(openPlatform), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // 弹完即解绑，恢复左键 toggle
    }

    @objc private func openPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        appState.refreshEnabledSources(trigger: .panelOpen)
    }

    @objc private func openPlatform() { PlatformPortal.shared.open() }

    @objc private func quit() { NSApp.terminate(nil) }

    func closePopover() { popover.performClose(nil) }
}
