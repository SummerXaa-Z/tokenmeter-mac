import AppKit
import SwiftUI

// 菜单栏外壳：状态栏图标 + NSPopover 承载 SwiftUI。
// 这是原生 macOS 菜单栏应用的标准做法——面板贴着状态栏图标下拉、带小箭头。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用：不占 Dock、不抢主菜单栏
        NSApp.setActivationPolicy(.accessory)

        // SwiftUI 根视图塞进 popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 600)
        popover.behavior = .transient   // 点外部自动收起
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(appState))

        // 状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusImage()
            button.image?.isTemplate = true   // 跟随明暗菜单栏自动反色
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        appState.rearmTimer()

        // 启动 5s 后做每日一次的更新检查（静默，仅有新版时弹窗）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.shared.autoCheckIfDue()
        }

        // 配额/用量预警：Codex 低配额 + Claude 日用量超阈值，状态栏图标统一变色
        refreshQuotaBadge()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuotaBadge() }
        }
    }

    private var quotaTimer: Timer?

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

    // 后台扫一次 Codex 配额 + Claude 今日用量，取两路最高等级给状态栏图标着色；
    // 正常水位/未启用监控时恢复模板图（跟随系统明暗）
    private func refreshQuotaBadge() {
        // 开关与阈值在主线程一次性快照，detached 任务里不再碰共享状态
        let codexOn = ConfigStore.shared.codexMonitorEnabled && CodexUsage.isAvailable
        let claudeLimitM = ConfigStore.shared.claudeDailyTokenLimitM
        let claudeOn = ConfigStore.shared.claudeMonitorEnabled
            && ClaudeUsage.isAvailable && claudeLimitM > 0
        guard codexOn || claudeOn else {
            setStatusIcon(tint: nil)
            return
        }
        Task.detached(priority: .utility) {
            var level = AlertLevel.normal

            if codexOn {
                let limits = CodexUsage.load().rateLimits
                let worstUsed = max(limits?.primary?.usedPercent ?? 0,
                                    limits?.secondary?.usedPercent ?? 0)
                let remaining = 100 - worstUsed
                if remaining <= 10 { level = max(level, .critical) }
                else if remaining <= 30 { level = max(level, .warn) }
            }

            if claudeOn {
                let todayTokens = ClaudeUsage.load().today?.totalTokens ?? 0
                let limit = claudeLimitM * 1_000_000
                // 超阈值即提醒，1.5 倍才升红——日用量越线不等于不可用，留缓冲
                if todayTokens >= limit * 3 / 2 { level = max(level, .critical) }
                else if todayTokens >= limit { level = max(level, .warn) }
            }

            let tint = level.tint
            await MainActor.run { [weak self] in
                self?.setStatusIcon(tint: tint)
            }
        }
    }

    private func setStatusIcon(tint: NSColor?) {
        guard let button = statusItem?.button else { return }
        if let tint {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            button.image = Self.statusImage()?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = Self.statusImage()
            button.image?.isTemplate = true
        }
    }

    // 状态栏图标：用 SF Symbol 生成模板图，缺失则回退到文字
    private static func statusImage() -> NSImage? {
        if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                             accessibilityDescription: "DeepSeek Monitor") {
            return img
        }
        return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "DeepSeek Monitor")
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
            appState.refreshAll()
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
        appState.refreshAll()
    }

    @objc private func openPlatform() { PlatformPortal.shared.open() }

    @objc private func quit() { NSApp.terminate(nil) }

    func closePopover() { popover.performClose(nil) }
}
