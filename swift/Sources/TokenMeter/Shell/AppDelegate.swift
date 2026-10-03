import AppKit
import SwiftUI
import UserNotifications

// 菜单栏外壳：状态栏图标 + NSPopover 承载 SwiftUI。
// 这是原生 macOS 菜单栏应用的标准做法——面板贴着状态栏图标下拉、带小箭头。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private let notificationRouter = NotificationRouter()
#if DEBUG
    private var smokeWindow: NSWindow?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 测试 host 仍由 XCTest 驱动，但不挂菜单、不采集、不请求通知或检查更新。
        if RuntimeEnvironment.isTesting { return }
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
        // 导出内置价格快照为 JSON（scripts/price-check.sh 与 OpenRouter 比对用）。
        if ProcessInfo.processInfo.arguments.contains("--dump-price-catalog") {
            FileHandle.standardOutput.write(
                Data(APIReferencePricingCatalog.jsonDump().utf8))
            exit(0)
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

        // 启动 10s 后低优先级回填按天明细（每约 7 天一次，见 DetailBackfill）：
        // 把实时 7 天窗之外的本地会话补进 model-history（滚动 90 天），让
        // 30D/全部 与各处上期基期立即可回溯
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            Task { await self.appState.backfillModelDetail() }
        }

        // 仅在用户开启通知时申请权限；关闭状态重启不能再次打扰用户。
        Notifier.requestAuthorizationIfEnabled(ConfigStore.shared.notificationsEnabled)

        // 注册周报通知的快捷动作分类（幂等）：横幅展开即可直接
        // 「导出上周 CSV」，不必打开面板走保存面板
        Notifier.registerCategories()

        // 周报/告警通知点击 → 打开对应页面并弹面板。delegate 是弱引用，
        // router 必须由 self 持有；回调统一回主线程后再碰 AppKit。
        notificationRouter.onOpen = { [weak self] target in
            self?.openPanelForNotification(target)
        }
        UNUserNotificationCenter.current().delegate = notificationRouter

        // 启动 5s 后做每日一次的更新检查（静默，仅有新版时弹窗）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.shared.autoCheckIfDue()
        }

        // 配额/用量预警 + 菜单栏信息文字，统一 15 分钟刷新；
        // 周报摘要的触发检查顺路搭同一节奏(自身按周去重,开销只是一次日期判断)
        requestQuotaBadgeRefresh()
        maybeSendWeeklyDigest()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestQuotaBadgeRefresh()
                self?.maybeSendWeeklyDigest()
            }
        }
        // 设置或余额状态变化后立刻生效，不等 15 分钟定时周期
        NotificationCenter.default.addObserver(forName: .statusRefreshRequested, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestQuotaBadgeRefresh() }
        }
    }

    private var quotaTimer: Timer?
    private var weeklyDigestLoading = false

#if DEBUG
    private func showUISmokeWindow() {
        PreviewData.seed(appState)
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TokenMeter UI Smoke · 示例数据"
        window.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(appState)
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        smokeWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runUIRender(outputPath: String) {
        DebugUIRenderHarness.render(appState: appState, outputPath: outputPath)
    }
#endif

    private var alertLatch = AlertLatch()
    // 本轮窗口内已提醒过的节奏预警 key(含窗口重置时刻)
    private var paceAlertedWindows: Set<String> = []
    private var statusRefreshCoalescer = StatusRefreshCoalescer()

    // 根据"当前是否越线"决定推/撤。crossed=true 且未推过 → 推；crossed=false → 清除记录
    // 额度节奏预警按窗口去重：同一窗口提醒过就不再提醒，即使节奏回落后
    // 又越线；窗口滚动、关源、清 Key 或关闭开关后 key 消失，重新布防。
    // 通知总开关关闭时不记已提醒，重新开启后当前越线窗口仍可提醒一次。
    private func evaluateQuotaPaceAlerts(codexOn: Bool) {
        let config = ConfigStore.shared
        let snapshot = SubscriptionQuotaSnapshot(
            codex: codexOn ? appState.codexRateLimits : nil,
            kimi: appState.kimiQuota.result,
            ark: appState.arkPlanQuota.result,
            zhipu: appState.zhipuQuota.result
        )
        let items = config.quotaPaceAlertEnabled ? QuotaPaceAlert.items(snapshot) : []
        paceAlertedWindows.formIntersection(items.map(\.key))
        guard config.notificationsEnabled else { return }
        for item in items where item.crossed && !paceAlertedWindows.contains(item.key) {
            paceAlertedWindows.insert(item.key)
            Notifier.send(id: item.key, title: item.title, body: item.body)
        }
    }

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

    // 每周一用量周报:周一至周三上午 9 点后、本周未发过时推一条上周摘要。
    // 无周报开关、不到时机直接返回;到时机但上周没用量也记下本周键,
    // 避免之后每个刷新周期重复读历史计算。
    private func maybeSendWeeklyDigest() {
        let store = ConfigStore.shared
        guard !weeklyDigestLoading, store.weeklyDigestEnabled,
              WeeklyDigest.isDue(lastSentWeek: store.lastWeeklyDigestWeek)
        else { return }
        weeklyDigestLoading = true
        let now = Date()
        let participants = WeeklyDigest.participants(store)
        let plans = store.subscriptionPlans
        Task { [weak self] in
            guard let self else { return }
            defer { self.weeklyDigestLoading = false }
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    (try HistoryStore.allChecked(now: now), try ModelUsageHistoryStore.shared.allChecked())
                }.value
                self.appState.reportHistoryReadOutcome(succeeded: true)
                guard store.weeklyDigestEnabled,
                      WeeklyDigest.isDue(lastSentWeek: store.lastWeeklyDigestWeek, today: now)
                else { return }
                // 确认历史成功读取后再记本周；读取失败仍允许下一轮重试。
                store.lastWeeklyDigestWeek = WeeklyDigest.weekKey(now)
                guard let message = WeeklyDigest.message(
                    snapshot.0, participants: participants, modelDays: snapshot.1,
                    plans: plans, today: now) else { return }
                Notifier.send(
                    id: Notifier.weeklyDigestID(forWeek: WeeklyDigest.summarizedWeekKey(today: now)),
                    title: message.title, body: message.body)
            } catch {
                self.appState.reportHistoryReadOutcome(succeeded: false)
            }
        }
    }

    private func finishQuotaBadgeRefresh() {
        if statusRefreshCoalescer.finish() {
            performQuotaBadgeRefresh()
        }
    }

    private func evaluateSubscriptionAlerts() {
        if let kimiResult = appState.kimiQuota.result {
            let worst = SubscriptionQuotaAlert.kimiWorstRemainingPercent(kimiResult)
            evaluateAlert(key: "kimi.quota.low", crossed: SubscriptionQuotaAlert.shouldNotify(remainingPercent: worst),
                          title: "Kimi Code 额度告急",
                          body: "订阅额度仅剩 \(worst.map { Int($0).description } ?? "0")%，留意用量")
        }
        if let zhipuResult = appState.zhipuQuota.result {
            let worst = SubscriptionQuotaAlert.zhipuWorstRemainingPercent(zhipuResult)
            evaluateAlert(key: "zhipu.quota.low", crossed: SubscriptionQuotaAlert.shouldNotify(remainingPercent: worst),
                          title: "智谱 GLM 额度告急",
                          body: "订阅额度仅剩 \(worst.map { Int($0).description } ?? "0")%，留意用量")
        }
        if let arkResult = appState.arkPlanQuota.result {
            let worst = SubscriptionQuotaAlert.arkWorstRemainingPercent(arkResult)
            evaluateAlert(key: "ark.quota.low", crossed: SubscriptionQuotaAlert.shouldNotify(remainingPercent: worst),
                          title: "火山方舟额度告急",
                          body: "订阅额度仅剩 \(worst.map { Int($0).description } ?? "0")%，留意用量")
        }
    }

    // 后台扫一次 Codex 配额 + Claude 今日用量：告警等级给图标着色，
    // 同时按设置把核心指标（Claude 今日 token / Codex 配额剩余 /
    // 「全部」档的全源今日合计）写到图标旁。
    private func performQuotaBadgeRefresh() {
        // 开关与阈值在主线程一次性快照，detached 任务里不再碰共享状态
        let settings = currentStatusRefreshSettings()
        let codexOn = settings.codexEnabled && (CodexUsage.isAvailable || appState.codexLiveQuotaEnabled)
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
        let allInfoOn = infoMode == "all"
        // 「全部」档参与源门禁与 refreshEnabledSources 一致（开关 + 本地数据可用），
        // 但不含 DeepSeek——平台账户不是 Coding Agent，不计入合计。
        let kimiOn = appState.kimiEnabled && KimiUsage.isAvailable
        let opencodeOn = appState.opencodeEnabled && OpenCodeUsage.isAvailable
        let geminiOn = appState.geminiEnabled && GeminiUsage.isAvailable
        let copilotOn = appState.copilotEnabled && CopilotUsage.isAvailable
        let qwenOn = appState.qwenEnabled && QwenCodeUsage.isAvailable
        let cursorOn = appState.cursorEnabled && CursorUsage.isAvailable

        // 用户明确关闭来源/阈值等同于重新布防；以后重新开启时应允许立即提醒。
        if balanceThreshold <= 0 { alertLatch.reset(key: "deepseek.balance.low") }
        if !codexOn { alertLatch.reset(key: "codex.quota.low") }
        if !claudeAlertOn { alertLatch.reset(key: "claude.daily.over") }
        // 配额数据消失（清除 Key 等）同样重新布防，避免下次仍越线时被旧状态吞掉
        if appState.kimiQuota.result == nil { alertLatch.reset(key: "kimi.quota.low") }
        if appState.zhipuQuota.result == nil { alertLatch.reset(key: "zhipu.quota.low") }
        if appState.arkPlanQuota.result == nil { alertLatch.reset(key: "ark.quota.low") }

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

        // 订阅额度预警同样与 Coding 源开关无关（只依赖配额缓存），照余额预警
        // 在 guard 前评估；配额缓存的刷新在下方 task group 里，加载完成后
        // 会自动再触发一轮状态栏刷新重新评估。
        evaluateSubscriptionAlerts()

        evaluateQuotaPaceAlerts(codexOn: codexOn)

        Task { [weak self] in
            guard let self else { return }
            var requested: Set<HistorySource> = []
            if codexOn { requested.insert(.codex) }
            if claudeAlertOn || claudeInfoOn || (allInfoOn && claudeUsable) { requested.insert(.claude) }
            if allInfoOn {
                requested.formUnion(SourceCatalog.codingAgentSources.filter {
                    self.appState.isSourceEnabled($0) && SourceCatalog.descriptor(for: $0).isAvailable()
                })
            }
            // 账户配额始终属于状态刷新计划，不能被菜单栏文本模式门禁跳过。
            await self.appState.refresh(scope: .status(usageSources: requested))

            var level = AlertLevel.normal
            var infoTokens = 0          // total/claude 模式累加今日 token
            var infoText: String?
            // 告警事实在后台算好，回主线程统一过状态机推送
            var codexCrossed: Bool?     // nil = 本轮未评估
            var codexRemaining = 0
            var claudeCrossed: Bool?
            var claudeToday = 0

            if codexOn {
                // 配额与本地会话独立；未生成会话文件时也能展示主动开启的实时配额。
                let limits = self.appState.codexRateLimits
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
                    infoTokens += self.appState.codex.result?.today?.totalTokens ?? 0
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
            if allInfoOn {
                // 「全部」档合计与总览页今日口径一致：live 优先、历史兜底。
                // 跨天旧缓存里的"今日"其实是昨天，不算 live，交给当日历史兜底。
                let now = Date()
                let recordedToday: [HistorySource: Int]
                do {
                    let history = try await Task.detached(priority: .utility) {
                        try HistoryStore.allChecked(now: now)
                    }.value
                    self.appState.reportHistoryReadOutcome(succeeded: true)
                    recordedToday = history.first { $0.date == DateUtil.key(now) }?.bySource ?? [:]
                } catch {
                    self.appState.reportHistoryReadOutcome(succeeded: false)
                    recordedToday = [:]
                    infoText = "—"
                }
                var participants: Set<HistorySource> = []
                var live: [HistorySource: Int] = [:]
                func collect(
                    _ on: Bool, _ source: HistorySource,
                    _ loadedAt: Date?, _ tokens: Int?
                ) {
                    guard on else { return }
                    participants.insert(source)
                    if let loadedAt,
                       Calendar.current.isDate(loadedAt, inSameDayAs: Date()) {
                        live[source] = tokens
                    }
                }
                collect(claudeUsable, .claude, self.appState.claude.loadedAt,
                        self.appState.claude.result?.today?.totalTokens)
                collect(codexOn, .codex, self.appState.codex.loadedAt,
                        self.appState.codex.result?.today?.totalTokens)
                collect(kimiOn, .kimi, self.appState.kimi.loadedAt,
                        self.appState.kimi.result?.today?.totalTokens)
                collect(opencodeOn, .opencode, self.appState.opencode.loadedAt,
                        self.appState.opencode.result?.today?.totalTokens)
                collect(geminiOn, .gemini, self.appState.gemini.loadedAt,
                        self.appState.gemini.result?.today?.totalTokens)
                collect(copilotOn, .copilot, self.appState.copilot.loadedAt,
                        self.appState.copilot.result?.today?.totalTokens)
                collect(qwenOn, .qwen, self.appState.qwen.loadedAt,
                        self.appState.qwen.result?.today?.totalTokens)
                collect(cursorOn, .cursor, self.appState.cursor.loadedAt,
                        self.appState.cursor.result?.dailyTokens(on: DateUtil.today()))
                infoTokens = MenubarTodayTotal.compute(
                    participants: participants,
                    live: live,
                    recordedToday: recordedToday
                )
            }
            // 订阅额度告警只染图标不发通知（通知在 guard 前已按边沿触发过），
            // 阈值线与 Codex 配额一致：≤30% 橙、≤10% 红。
            let kimiWorst = self.appState.kimiQuota.result
                .flatMap(SubscriptionQuotaAlert.kimiWorstRemainingPercent)
            let zhipuWorst = self.appState.zhipuQuota.result
                .flatMap(SubscriptionQuotaAlert.zhipuWorstRemainingPercent)
            let arkWorst = self.appState.arkPlanQuota.result
                .flatMap(SubscriptionQuotaAlert.arkWorstRemainingPercent)
            for worst in [kimiWorst, zhipuWorst, arkWorst].compactMap({ $0 }) {
                if SubscriptionQuotaAlert.isCritical(worst) { level = max(level, .critical) }
                else if SubscriptionQuotaAlert.isWarn(worst) { level = max(level, .warn) }
            }

            if infoText == nil, claudeInfoOn || codexTotalInfoOn || allInfoOn {
                infoText = Fmt.tokensShort(infoTokens)
            }

            // 设置变更会另外请求一次合并刷新。旧任务只负责结束并触发补跑，
            // 不能再用旧来源/阈值更新图标或发通知。
            guard settings.isCurrent(self.currentStatusRefreshSettings()) else {
                self.finishQuotaBadgeRefresh()
                return
            }

            self.evaluateSubscriptionAlerts()
            self.evaluateQuotaPaceAlerts(codexOn: codexOn)
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

    // 点击通知（周报/配额告警）：请求跳到目标页（面板已开在别的页时也会
    // 导航），再弹面板。与 @objc 的 openPanel() 分开命名,避免选择器歧义。
    private func openPanelForNotification(_ target: AppView) {
        appState.pendingView = target
        openPanel()
    }

    @objc private func openPlatform() { PlatformPortal.shared.open() }

    @objc private func quit() { NSApp.terminate(nil) }

    func closePopover() { popover.performClose(nil) }
}

// 通知点击路由：把「横幅本身的点击」映射为目标页面（Notifier.openTarget），
// 派生动作与其他通知交还系统默认行为。周报的快捷动作（导出上周 CSV）
// 在这里就地执行：不开面板、不弹保存面板，直接把 CSV 写到「下载」文件
// 夹并回执一条结果通知。UNUserNotificationCenter 的 delegate 是弱引用，
// 实例由 AppDelegate 持有；回调回主线程后再碰 AppKit。
private final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((AppView) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Notifier.weeklyDigestExportActionID {
            handleWeeklyDigestExport()
            completionHandler()
            return
        }
        if let target = Notifier.openTarget(
            identifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier)
        {
            DispatchQueue.main.async { [weak self] in
                self?.onOpen?(target)
            }
        }
        completionHandler()
    }

    /// 周报快捷动作的直落导出：与设置页「导出上周 CSV」同一条数据管线
    ///（上周周一到周日、含汇总与订阅回本行），只是不经保存面板，直接
    /// 写「下载」文件夹；结果回执一条系统通知（文件名或失败原因）。
    private func handleWeeklyDigestExport() {
        guard !RuntimeEnvironment.isIsolated else { return }
        Task { @MainActor in
            let plans = ConfigStore.shared.subscriptionPlans
            let filename: String?
            do {
                filename = try await Task.detached(priority: .utility) {
                    guard let directory = FileManager.default.urls(
                        for: .downloadsDirectory, in: .userDomainMask).first else { return nil as String? }
                    let days = try HistoryStore.allChecked()
                    let models = try ModelUsageHistoryStore.shared.allChecked()
                    return UsageCSVExport.writeLastWeekCSV(
                        directory: directory, days: days,
                        apiValueByDate: UsageCSVExport.apiValueByDate(models),
                        modelHistory: models, plans: plans)
                }.value
            } catch {
                filename = nil
            }
            Notifier.send(
                id: "weekly.digest.export.result",
                title: filename == nil ? "上周 CSV 导出失败" : "已导出上周 CSV",
                body: filename.map { "已写入「下载」文件夹：\($0)" }
                    ?? "无法确认本地历史或写入失败；可到 设置 → 用量导出 手动导出")
        }
    }
}
