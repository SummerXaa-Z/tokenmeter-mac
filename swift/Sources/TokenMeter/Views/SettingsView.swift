import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void
    var onOpenConfigSync: () -> Void

    private let store = ConfigStore.shared
    @State private var apiKeyInput = ""
    @State private var apiStatus = ""
    @State private var usageTokenInput = ""
    @State private var usageStatus = ""
    @State private var kimiCodeKeyInput = ""
    @State private var kimiCodeKeyStatus = ""
    @State private var showManualPaste = false
    @State private var busy = false
    @State private var syncing = false
    @State private var autostartOn = false
    @State private var autoUpdateOn = true
    @State private var notificationsOn = true
    @State private var balanceAlert = 0
    @State private var diagnosticStatus = ""
    @State private var assetSyncSourceDraft = ""

    @StateObject private var sync = LoginSyncController()
    @ObservedObject private var updater = Updater.shared

    private let codingProviders: [Provider] = [
        .claude, .codex, .kimi, .opencode, .gemini, .copilot, .qwen, .cursor,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: 44)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle(
                        "数据来源",
                        hint: "控制 Coding 用量采集；订阅额度连接在下方单独管理"
                    )
                    sourcesSection

                    sectionTitle(
                        "平台账户与额度",
                        hint: "DeepSeek 与 Kimi 需要连接；Codex、方舟读取本机已有登录态"
                    )
                    deepSeekAccountSection
                    kimiQuotaKeySection

                    sectionTitle(
                        "菜单栏与提醒",
                        hint: "选择常驻信息，并设置只在越线时触发一次的提醒"
                    )
                    displayAndAlertsSection

                    sectionTitle(
                        "刷新与启动",
                        hint: "管理后台采集频率与 macOS 登录启动"
                    )
                    runtimeSection

                    sectionTitle(
                        "工具与维护",
                        hint: "配置同步、软件更新与脱敏诊断"
                    )
                    maintenanceSection
                    footer
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            reloadStatus()
            Task { await prepareAssetSyncSettings() }
        }
        .onReceive(sync.$captured.compactMap { $0 }) { _ in
            syncing = false
            usageStatus = "已通过网页登录自动同步，正在刷新…"
            Task { await refreshUsageAfterToken("已自动同步用量 Token") }
        }
        .onReceive(sync.$ended) { ended in
            if ended {
                syncing = false
                usageStatus = "登录窗口已关闭，未获取到 Token。可重新同步或手动输入。"
            }
        }
        .onReceive(sync.$persistenceError.compactMap { $0 }) { message in
            syncing = false
            usageStatus = message
        }
    }

    private func sectionTitle(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .bold))
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            Text("设置").font(.system(size: 15, weight: .bold))
            Spacer()
        }
    }

    // MARK: - 数据来源

    private var availableCodingProviders: [Provider] {
        codingProviders.filter(\.available)
    }

    private var unavailableCodingProviders: [Provider] {
        codingProviders.filter { !$0.available }
    }

    private var sourcesSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(availableCodingProviders.enumerated()), id: \.element.id) { index, provider in
                    sourceToggleRow(provider)
                    if index < availableCodingProviders.count - 1 {
                        Divider().padding(.leading, 36)
                    }
                }
                if !unavailableCodingProviders.isEmpty {
                    if !availableCodingProviders.isEmpty {
                        Divider().padding(.leading, 36)
                    }
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 27, height: 27)
                        Text("未检测到：\(unavailableCodingProviders.map(providerDisplayName).joined(separator: "、"))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, availableCodingProviders.isEmpty ? 0 : 7)
                }
            }
        }
    }

    private func sourceToggleRow(_ provider: Provider) -> some View {
        Toggle(isOn: sourceBinding(provider)) {
            HStack(spacing: 9) {
                Image(systemName: providerIcon(provider))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(providerColor(provider))
                    .frame(width: 27, height: 27)
                    .background(
                        providerColor(provider).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(providerDisplayName(provider))
                            .font(.system(size: 12, weight: .semibold))
                        Text(provider == .cursor ? "账户" : "本地")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(providerSubtitle(provider))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel(providerDisplayName(provider))
        .accessibilityHint(providerSubtitle(provider))
        .padding(.vertical, 7)
        .accessibilityIdentifier("TokenMeter.Settings.Source.\(provider.rawValue)")
    }

    private func sourceBinding(_ provider: Provider) -> Binding<Bool> {
        switch provider {
        case .claude:
            return Binding(get: { state.claudeEnabled }, set: { state.setClaudeEnabled($0) })
        case .codex:
            return Binding(get: { state.codexEnabled }, set: { state.setCodexEnabled($0) })
        case .kimi:
            return Binding(get: { state.kimiEnabled }, set: { state.setKimiEnabled($0) })
        case .opencode:
            return Binding(get: { state.opencodeEnabled }, set: { state.setOpenCodeEnabled($0) })
        case .gemini:
            return Binding(get: { state.geminiEnabled }, set: { state.setGeminiEnabled($0) })
        case .copilot:
            return Binding(get: { state.copilotEnabled }, set: { state.setCopilotEnabled($0) })
        case .qwen:
            return Binding(get: { state.qwenEnabled }, set: { state.setQwenEnabled($0) })
        case .cursor:
            return Binding(get: { state.cursorEnabled }, set: { state.setCursorEnabled($0) })
        case .deepseek, .configsync:
            return .constant(false)
        }
    }

    private func providerDisplayName(_ provider: Provider) -> String {
        switch provider {
        case .gemini: return "Gemini CLI"
        case .copilot: return "GitHub Copilot CLI"
        case .qwen: return "Qwen Code"
        default: return provider.rawValue
        }
    }

    private func providerSubtitle(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "transcript 用量"
        case .codex: return "session 用量与订阅配额"
        case .kimi: return "usage journal；不影响订阅额度"
        case .opencode: return "SQLite 消息用量"
        case .gemini: return "session 用量"
        case .copilot: return "session 汇总"
        case .qwen: return "官方 session 聚合用量"
        case .cursor: return "通过 cursor.com 查询账户用量"
        case .deepseek, .configsync: return ""
        }
    }

    private func providerIcon(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .kimi: return "moon.stars"
        case .opencode: return "curlybraces"
        case .gemini: return "wand.and.stars"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .qwen: return "q.circle"
        case .cursor: return "cursorarrow.rays"
        case .deepseek: return "server.rack"
        case .configsync: return "arrow.triangle.2.circlepath"
        }
    }

    private func providerColor(_ provider: Provider) -> Color {
        switch provider {
        case .claude: return Theme.claude
        case .codex: return Theme.codex
        case .kimi: return Theme.kimi
        case .opencode: return Theme.opencode
        case .gemini: return Theme.gemini
        case .copilot: return Theme.copilot
        case .qwen: return Theme.qwen
        case .cursor: return Theme.cursor
        case .deepseek: return Theme.brand
        case .configsync: return .secondary
        }
    }

    // MARK: - 平台账户与额度

    private var deepSeekAccountSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { state.deepseekEnabled },
                    set: { state.setDeepseekEnabled($0) }
                )) {
                    HStack(spacing: 9) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 27, height: 27)
                            .background(
                                Theme.brand.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DeepSeek 开放平台")
                                .font(.system(size: 12, weight: .semibold))
                            Text("余额与 API 消费 · 不计入 Coding 合计")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel("DeepSeek 开放平台")
                .accessibilityHint("余额与 API 消费，不计入 Coding 合计")

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("余额连接", systemImage: "key")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        credentialStatusBadge(apiStatus, configured: store.apiKeyConfigured)
                    }
                    Text("API Key 仅存本机 Keychain，用于查询平台余额。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    SecureField("sk-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("验证并保存") { saveApiKey() }
                            .disabled(busy || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("清除") { clearApiKey() }
                            .disabled(busy || !store.apiKeyConfigured)
                        Spacer()
                    }
                    if !apiStatus.isEmpty {
                        Text(apiStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("平台消费连接", systemImage: "chart.bar.doc.horizontal")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        credentialStatusBadge(usageStatus, configured: store.usageTokenConfigured)
                    }
                    Text("DeepSeek 未开放用量 API，需网页登录授权；Token 仍只存本机。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(syncing ? "等待登录完成…" : "网页登录授权") { startSync() }
                            .disabled(syncing)
                        Button(showManualPaste ? "收起手动输入" : "手动输入 Token") {
                            showManualPaste.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.brand)
                        .accessibilityIdentifier("TokenMeter.Settings.DeepSeek.ManualToken")
                    }
                    if showManualPaste {
                        Text("浏览器控制台执行 JSON.parse(localStorage.userToken).value 后复制结果")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        SecureField("粘贴 Token", text: $usageTokenInput)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("验证并保存") { saveUsageToken() }
                                .disabled(
                                    busy || usageTokenInput
                                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                )
                            Button("清除") { clearUsageToken() }
                                .disabled(busy || !store.usageTokenConfigured)
                            Spacer()
                        }
                    }
                    if !usageStatus.isEmpty {
                        Text(usageStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    private func credentialStatusBadge(_ status: String, configured: Bool) -> some View {
        Text(configured ? "已连接" : "未连接")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(configured ? Color.green : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (configured ? Color.green : Color.secondary).opacity(0.12),
                in: Capsule()
            )
            .accessibilityLabel(status.isEmpty ? (configured ? "已连接" : "未连接") : status)
    }

    private var kimiQuotaKeySection: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Kimi For Coding Key", systemImage: "key.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                Text("仅用于官方 5 小时、周额度与 Extra Usage；本地 Kimi 用量不需要 Key。请求只发往 Kimi 官方，且不读取 Kimi.app 或 CC Switch 私有配置。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("粘贴 Kimi For Coding Key", text: $kimiCodeKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("验证并保存") { saveKimiCodeKey() }
                        .disabled(
                            busy || kimiCodeKeyInput
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    Button("清除") { clearKimiCodeKey() }
                        .disabled(busy || !store.kimiCodeKeyConfigured)
                    Spacer()
                }
                if !kimiCodeKeyStatus.isEmpty {
                    Text(kimiCodeKeyStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    // MARK: - 菜单栏与提醒

    private var displayAndAlertsSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("菜单栏显示", systemImage: "menubar.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: Binding(
                        get: { state.menubarInfoMode },
                        set: { state.setMenubarInfoMode($0) }
                    )) {
                        Text("关闭").tag("off")
                        Text("Claude + Codex").tag("total")
                        Text("Claude").tag("claude")
                        Text("Codex 额度").tag("codex")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("“Claude + Codex”只显示这两个工具的今日合计，不代表首页全部 Coding 来源。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

                Divider()
                Toggle(isOn: Binding(
                    get: { notificationsOn },
                    set: { value in
                        store.notificationsEnabled = value
                        notificationsOn = value
                        Notifier.requestAuthorizationIfEnabled(value)
                        NotificationCenter.default.post(
                            name: .statusRefreshRequested,
                            object: nil
                        )
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统通知").font(.system(size: 12, weight: .semibold))
                        Text("Codex 配额 ≤10%、Claude 超阈值或 DeepSeek 余额过低时，仅在越线时提醒一次")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Claude 日用量阈值")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("", selection: Binding(
                        get: { state.claudeDailyLimitM },
                        set: { state.setClaudeDailyLimit($0) }
                    )) {
                        Text("关").tag(0)
                        Text("100M").tag(100)
                        Text("300M").tag(300)
                        Text("500M").tag(500)
                        Text("1000M").tag(1000)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("达到阈值后图标变橙，达到 1.5 倍变红；通知开启时同步提醒。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .disabled(!state.claudeEnabled || !ClaudeUsage.isAvailable)

                VStack(alignment: .leading, spacing: 5) {
                    Text("DeepSeek 余额提醒")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("", selection: Binding(
                        get: { balanceAlert },
                        set: {
                            store.deepseekBalanceAlertThreshold = $0
                            balanceAlert = $0
                            NotificationCenter.default.post(
                                name: .statusRefreshRequested,
                                object: nil
                            )
                        }
                    )) {
                        Text("关").tag(0)
                        Text("¥20").tag(20)
                        Text("¥50").tag(50)
                        Text("¥100").tag(100)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - 刷新与启动

    private var runtimeSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { state.autoRefreshEnabled },
                    set: { state.setAutoRefresh($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("自动刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                        Text("刷新已启用来源；订阅额度与本地 Kimi 用量彼此独立")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Picker("间隔", selection: Binding(
                    get: { state.refreshIntervalSeconds },
                    set: { state.setRefreshInterval($0) }
                )) {
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("30 分钟").tag(1800)
                    Text("1 小时").tag(3600)
                }
                .pickerStyle(.segmented)
                .disabled(!state.autoRefreshEnabled)

                Divider()
                Toggle(isOn: Binding(
                    get: { autostartOn },
                    set: { enabled in autostartOn = Autostart.apply(enabled) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("登录时启动", systemImage: "power")
                            .font(.system(size: 12, weight: .semibold))
                        Text("登录 macOS 后自动运行 TokenMeter")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 工具与维护

    private var maintenanceSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { state.assetSyncEnabled },
                    set: { enabled in handleAssetSyncToggle(enabled) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("自动同步 Agent 资产", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                        Text(AgentSyncService.isAvailable
                             ? "打开后按真源自动补齐所有兼容 Agent；写前预演并备份"
                             : "未检测到 agentsync CLI")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .disabled(!AgentSyncService.isAvailable || state.assetSync.loading)

                if AgentSyncService.isAvailable {
                    assetSyncPlanControls
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("软件更新", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Toggle("每日自动检查一次", isOn: Binding(
                        get: { autoUpdateOn },
                        set: { value in
                            store.autoUpdateCheckEnabled = value
                            autoUpdateOn = value
                        }
                    ))
                    HStack {
                        Button(updateButtonTitle) { updateAction() }.disabled(updateBusy)
                        Spacer()
                    }
                    if !updateStatusText.isEmpty {
                        Text(updateStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("脱敏诊断", systemImage: "stethoscope")
                        .font(.system(size: 12, weight: .semibold))
                    Text("导出版本、系统、签名、数据源与工具状态；不包含凭据或会话内容。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("导出诊断信息") { exportDiagnostics() }
                        Spacer()
                    }
                    if !diagnosticStatus.isEmpty {
                        Text(diagnosticStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var assetSyncProfiles: [ConfigProfile] {
        state.configSync.result?.profiles ?? []
    }

    private var assetSyncSourceProfiles: [ConfigProfile] {
        assetSyncProfiles.filter(AgentAssetSyncSelection.isValidSource)
    }

    private var assetSyncPlanControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("真源")
                    .font(.system(size: 11, weight: .semibold))
                Picker("", selection: $assetSyncSourceDraft) {
                    Text("请选择").tag("")
                    ForEach(assetSyncSourceProfiles) { profile in
                        Text(profile.label).tag(profile.key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(state.assetSyncEnabled || state.configSync.loading)
                Spacer(minLength: 0)
                if state.assetSync.loading {
                    ProgressView().controlSize(.small)
                } else if state.assetSyncEnabled {
                    Button("立即同步") { state.runAssetSyncNow() }
                        .font(.system(size: 10))
                }
            }

            if let summary = assetSyncPlanSummary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.configSync.loading {
                Text("正在扫描本机 Agent 资产能力…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if assetSyncSourceProfiles.isEmpty {
                Text("没有找到包含可同步资产的真源")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            } else {
                Text("首次只需确认一次真源；之后新安装的兼容 Agent 会自动纳入。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if let message = state.assetSync.error, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(message.contains("冲突") ? .orange : .red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let last = store.assetSyncLastSuccessAt {
                Text("上次成功：\(relativeAssetSyncTime(last))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Toggle(isOn: Binding(
                get: { state.configSyncEnabled },
                set: { state.setConfigSyncEnabled($0) }
            )) {
                Text("显示高级配置同步与回滚入口")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if state.configSyncEnabled {
                Button("打开高级同步与回滚") {
                    onOpenConfigSync()
                }
                .font(.system(size: 10))
            }
        }
        .padding(.leading, 36)
    }

    private var assetSyncPlanSummary: String? {
        guard let profile = assetSyncSourceProfiles.first(where: {
            $0.key == assetSyncSourceDraft
        }) else { return nil }
        let groups = AgentAssetSyncSelection.layerTargets(
            sourceKey: profile.key,
            profiles: assetSyncProfiles
        )
        let layerNames: [String: String] = [
            "mcp": "MCP", "rules": "规则", "skills": "Skills",
            "commands": "Commands", "agents": "Agents", "hooks": "Hooks",
        ]
        let parts = groups.compactMap { group -> String? in
            guard !group.targetKeys.isEmpty else { return nil }
            return "\(layerNames[group.layer] ?? group.layer) → \(group.targetKeys.count) 个"
        }
        guard !parts.isEmpty else { return "当前没有兼容的推送目标" }
        return "当前适配：\(profile.label) 为真源 · " + parts.joined(separator: " · ")
    }

    private func prepareAssetSyncSettings() async {
        guard AgentSyncService.isAvailable else { return }
        // 高级入口即使被隐藏，一键同步设置也需要一次只读 scan。
        await state.loadConfigSync(force: true, allowHidden: true)

        if state.assetSyncEnabled {
            guard let saved = state.assetSyncSourceKey,
                  let profile = assetSyncProfiles.first(where: { $0.key == saved }),
                  AgentAssetSyncSelection.isValidSource(profile)
            else {
                assetSyncSourceDraft = ""
                state.assetSync.error = "已暂停：原真源当前没有可同步资产；关闭开关后可重新选择"
                return
            }
            assetSyncSourceDraft = saved
            return
        }

        if let choice = AgentAssetSyncSelection.sourceChoice(
            savedSourceKey: state.assetSyncSourceKey,
            profiles: assetSyncProfiles
        ) {
            assetSyncSourceDraft = choice.sourceKey
            if choice.origin == .saved {
                state.confirmAssetSyncSource(choice.sourceKey)
            }
        } else {
            assetSyncSourceDraft = ""
        }
    }

    private func handleAssetSyncToggle(_ enabled: Bool) {
        if !enabled {
            state.setAssetSyncEnabled(false)
            return
        }
        guard !assetSyncSourceDraft.isEmpty else {
            state.assetSync.error = "请先确认一个 Agent 作为资产真源"
            return
        }
        // 用户打开开关就是对当前可见真源的唯一一次明确确认。
        state.confirmAssetSyncSource(assetSyncSourceDraft)
        state.setAssetSyncEnabled(true)
    }

    private func relativeAssetSyncTime(_ timestamp: TimeInterval) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: timestamp),
            relativeTo: Date()
        )
    }

    private var updateBusy: Bool {
        switch updater.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var updateButtonTitle: String {
        switch updater.phase {
        case .checking: return "正在检查…"
        case .downloading: return "正在下载…"
        case .installing: return "正在安装…"
        case .available(let version): return "下载并更新到 v\(version)"
        default: return "检查更新"
        }
    }

    private var updateStatusText: String {
        switch updater.phase {
        case .upToDate: return "已是最新版本 v\(Updater.currentVersion)"
        case .available(let version): return "发现新版本 v\(version)，更新后应用会自动重启"
        case .failed(let message): return message
        default: return ""
        }
    }

    private func updateAction() {
        if case .available = updater.phase {
            Task { await updater.downloadAndInstall() }
        } else {
            Task { await updater.check() }
        }
    }

    private func exportDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出诊断信息"
        panel.nameFieldStringValue = DiagnosticReport.currentFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticReport.currentText().write(to: url, atomically: true, encoding: .utf8)
            diagnosticStatus = "已导出：\(url.lastPathComponent)"
        } catch {
            diagnosticStatus = "导出失败：\(error.localizedDescription)"
        }
    }

    private var footer: some View {
        Text("TokenMeter v\(Updater.currentVersion) · 凭据只存本机 Keychain · 用量绝不上报")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Actions

    private func reloadStatus() {
        apiStatus = store.apiKeyConfigured
            ? "已配置 \(store.apiKeyPreview() ?? "")"
            : "未配置 API Key"
        usageStatus = store.usageTokenConfigured ? "用量 Token 已配置" : "未配置用量 Token"
        kimiCodeKeyStatus = store.kimiCodeKeyConfigured
            ? "已配置 \(store.kimiCodeKeyPreview() ?? "")，额度走 Kimi 官方接口"
            : "未配置；仅在 standalone kimi web 运行时尝试本机额度接口"
        autostartOn = Autostart.isEnabled
        autoUpdateOn = store.autoUpdateCheckEnabled
        notificationsOn = store.notificationsEnabled
        balanceAlert = store.deepseekBalanceAlertThreshold
    }

    private func saveApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            apiStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 API Key"
            return
        }
        busy = true
        apiStatus = "正在验证 DeepSeek 余额连接…"
        Task {
            do {
                let balance = try await DeepSeekAPI.fetchBalance(apiKey: key)
                try store.saveDeepSeekAPIKey(key)
                apiKeyInput = ""
                apiStatus = "验证通过，当前余额 \(balance.symbol)\(balance.totalBalance)\(balance.isAvailable ? "" : "（余额不足）")"
                await state.loadBalance(force: true)
            } catch {
                apiStatus = (error as? CredentialStoreError)?.errorDescription
                    ?? (error as? APIError)?.errorDescription
                    ?? "API Key 验证失败，未覆盖原凭据"
            }
            busy = false
        }
    }

    private func clearApiKey() {
        busy = true
        do {
            try store.clearDeepSeekAPIKey()
        } catch {
            apiStatus = (error as? CredentialStoreError)?.errorDescription
                ?? "API Key 清除失败"
            busy = false
            return
        }
        apiKeyInput = ""
        apiStatus = "已清除 API Key"
        Task {
            await state.loadBalance(force: true)
            busy = false
        }
    }

    private func saveKimiCodeKey() {
        let key = kimiCodeKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            kimiCodeKeyStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 Key"
            return
        }
        busy = true
        kimiCodeKeyStatus = "正在验证 Kimi 官方额度…"
        Task {
            do {
                let result = try await KimiQuotaService().load(apiKey: key)
                try store.saveKimiCodeKey(key)
                kimiCodeKeyInput = ""
                state.invalidateKimiQuota()
                state.kimiQuota.result = result
                let now = Date()
                state.kimiQuota.loadedAt = now
                state.kimiQuota.succeededAt = now
                state.kimiQuota.error = nil
                let windowCount = (result.summary == nil ? 0 : 1) + result.limits.count
                kimiCodeKeyStatus = "验证通过，已读取 \(windowCount) 个额度窗口"
            } catch {
                kimiCodeKeyStatus = (error as? KimiQuotaError)?.errorDescription
                    ?? (error as? CredentialStoreError)?.errorDescription
                    ?? "Kimi For Coding Key 验证失败"
            }
            busy = false
        }
    }

    private func clearKimiCodeKey() {
        busy = true
        do {
            try store.clearKimiCodeKey()
        } catch {
            kimiCodeKeyStatus = (error as? CredentialStoreError)?.errorDescription
                ?? "Kimi For Coding Key 清除失败"
            busy = false
            return
        }
        kimiCodeKeyInput = ""
        state.invalidateKimiQuota()
        kimiCodeKeyStatus = "已清除；正在尝试本机 kimi web 额度接口…"
        Task {
            await state.loadKimiQuota(force: true)
            kimiCodeKeyStatus = state.kimiQuota.result == nil
                ? (state.kimiQuota.error ?? "未获得本机 Kimi Code 配额")
                : "已切换为本机 Kimi Code 配额接口"
            busy = false
        }
    }

    private func startSync() {
        guard !syncing else { return }
        syncing = true
        usageStatus = "请在登录窗口完成登录；捕获成功后会自动关闭并刷新。"
        _ = sync.start()
    }

    private func saveUsageToken() {
        let token = usageTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            usageStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 Token"
            return
        }
        busy = true
        usageStatus = "正在验证用量 Token…"
        Task {
            let now = Date()
            let components = Calendar.current.dateComponents([.month, .year], from: now)
            let valid = await DeepSeekAPI.verifyUsageToken(
                token,
                month: components.month ?? 1,
                year: components.year ?? 2026
            )
            guard valid else {
                usageStatus = "Token 验证失败，未覆盖原凭据"
                busy = false
                return
            }
            do {
                try store.saveDeepSeekUsageToken(token)
                usageTokenInput = ""
                await refreshUsageAfterToken("验证通过，已保存")
            } catch {
                usageStatus = (error as? CredentialStoreError)?.errorDescription
                    ?? "用量 Token 保存失败"
            }
            busy = false
        }
    }

    private func clearUsageToken() {
        busy = true
        do {
            try store.clearDeepSeekUsageToken()
        } catch {
            usageStatus = (error as? CredentialStoreError)?.errorDescription
                ?? "用量 Token 清除失败"
            busy = false
            return
        }
        usageTokenInput = ""
        usageStatus = "已清除用量 Token"
        state.clearUsage()
        busy = false
    }

    private func refreshUsageAfterToken(_ prefix: String) async {
        await state.loadUsage(force: true)
        if case .ok = state.usageState, let usage = state.usage {
            usageStatus = "\(prefix)，本月消费 \(Fmt.money(usage.monthCost))"
        } else if case .error(let message) = state.usageState {
            usageStatus = "\(prefix)，但用量刷新失败：\(message)"
        }
    }
}
