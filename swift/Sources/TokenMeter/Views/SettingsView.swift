import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void

    private let store = ConfigStore.shared
    @State private var apiKeyInput = ""
    @State private var apiStatus = ""
    @State private var usageTokenInput = ""
    @State private var usageStatus = ""
    @State private var kimiCodeKeyInput = ""
    @State private var kimiCodeKeyStatus = ""
    @State private var zhipuKeyInput = ""
    @State private var zhipuKeyStatus = ""
    @State private var showManualPaste = false
    @State private var busy = false
    @State private var syncing = false
    @State private var autostartOn = false
    @State private var autoUpdateOn = true
    @State private var notificationsOn = true
    @State private var balanceAlert = 0
    @State private var diagnosticStatus = ""
    @State private var usageExportStatus = ""
    // 连接行的展开态：未配置的默认展开引导输入，已配置的收起成一行；
    // 验证保存成功后自动收起，清除后保持展开方便重输。
    @State private var expandBalanceKey = false
    @State private var expandUsageToken = false
    @State private var expandKimiKey = false
    @State private var expandZhipuKey = false
    @State private var expansionInitialized = false

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
                    sectionTitle("数据来源")
                    sourcesSection

                    sectionTitle("平台账户与额度")
                    accountsSection

                    sectionTitle("菜单栏与提醒")
                    displayAndAlertsSection

                    sectionTitle("刷新与启动")
                    runtimeSection

                    sectionTitle("工具与维护")
                    maintenanceSection
                    footer
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            if !expansionInitialized {
                expandBalanceKey = !store.apiKeyConfigured
                expandUsageToken = !store.usageTokenConfigured
                expandKimiKey = !store.kimiCodeKeyConfigured
                expandZhipuKey = !store.zhipuKeyConfigured
                expansionInitialized = true
            }
            reloadStatus()
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .bold))
    }

    private var header: some View {
        HStack(spacing: 10) {
            SourceDashboardIconButton(name: "chevron.left", help: "返回上一页", action: onBack)
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
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(providerSubtitle(provider))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // 撑满剩余宽度，让所有开关统一靠右成一列
                .frame(maxWidth: .infinity, alignment: .leading)
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
        case .deepseek:
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
        case .deepseek: return ""
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
        }
    }

    // MARK: - 平台账户与额度

    // 四个连接共用一张卡、同一套行结构：标题行（图标 + 名称 + 连接状态徽章 +
    // 展开箭头）点击展开输入区。已配置的默认收起，避免整页空输入框。
    private var accountsSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
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
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        // 与数据来源行一致：文字撑满，开关统一靠右
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel("DeepSeek 开放平台")
                .accessibilityHint("余额与 API 消费，不计入 Coding 合计")
                .padding(.vertical, 7)

                Divider().padding(.leading, 36)
                connectionBalance
                Divider().padding(.leading, 36)
                connectionUsage
                Divider().padding(.leading, 36)
                connectionKimi
                Divider().padding(.leading, 36)
                connectionZhipu
            }
        }
    }

    private var connectionBalance: some View {
        AccountConnectionRow(
            icon: "key",
            tint: Theme.brand,
            title: "余额查询",
            detail: "API Key 查询平台余额，只存本机 Keychain",
            configured: store.apiKeyConfigured,
            statusText: apiStatus,
            expanded: $expandBalanceKey
        ) {
            SecureField("sk-...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("验证并保存") { saveApiKey() }
                    .disabled(busy || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("清除") { clearApiKey() }
                    .disabled(busy || !store.apiKeyConfigured)
                Spacer()
            }
        }
    }

    private var connectionUsage: some View {
        AccountConnectionRow(
            icon: "chart.bar.doc.horizontal",
            tint: Theme.brand,
            title: "平台消费查询",
            detail: "需网页登录授权；Token 仍只存本机",
            configured: store.usageTokenConfigured,
            statusText: usageStatus,
            expanded: $expandUsageToken
        ) {
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
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
        }
    }

    private var connectionKimi: some View {
        AccountConnectionRow(
            icon: "key.viewfinder",
            tint: Theme.kimi,
            title: "Kimi Coding 订阅额度",
            detail: "官方 5 小时 / 周额度查询；本地用量无需 Key",
            configured: store.kimiCodeKeyConfigured,
            statusText: kimiCodeKeyStatus,
            expanded: $expandKimiKey
        ) {
            Text("仅用于官方 5 小时、周额度与 Extra Usage；请求只发往 Kimi 官方，不读取 Kimi.app 或 CC Switch 私有配置。")
                .font(.system(size: 11))
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
        }
    }

    private var connectionZhipu: some View {
        AccountConnectionRow(
            icon: "key.viewfinder",
            tint: Theme.zhipu,
            title: "智谱 GLM 订阅额度",
            detail: "Coding Plan 额度与工具调用次数查询",
            configured: store.zhipuKeyConfigured,
            statusText: zhipuKeyStatus,
            expanded: $expandZhipuKey
        ) {
            Text("Key 只存本机 Keychain，只发往所选域名的官方接口。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(
                "接口域名",
                selection: Binding(
                    get: { store.zhipuQuotaDomain },
                    set: { domain in
                        guard domain != store.zhipuQuotaDomain else { return }
                        store.zhipuQuotaDomain = domain
                        if store.zhipuKeyConfigured {
                            state.invalidateZhipuQuota()
                            Task { await state.loadZhipuQuota(force: true) }
                        }
                    }
                )
            ) {
                Text("国内版").tag(ZhipuQuotaDomain.china)
                Text("国际版").tag(ZhipuQuotaDomain.international)
            }
            .pickerStyle(.segmented)
            SecureField("粘贴智谱 API Key", text: $zhipuKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("验证并保存") { saveZhipuKey() }
                    .disabled(
                        busy || zhipuKeyInput
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                Button("清除") { clearZhipuKey() }
                    .disabled(busy || !store.zhipuKeyConfigured)
                Spacer()
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
                        Text("全部").tag("all")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("「Claude + Codex」只计这两个工具的今日合计；「全部」为今日所有已启用 Coding 来源的合计（不含 DeepSeek 平台账户），与首页口径一致。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
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
                        Text("Codex / Kimi / 智谱 / 方舟额度 ≤10%、Claude 超阈值或 DeepSeek 余额过低时，仅在越线时提醒一次")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Claude 日用量阈值")
                        .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .disabled(!state.claudeEnabled || !ClaudeUsage.isAvailable)

                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("DeepSeek 余额提醒")
                        .font(.system(size: 12, weight: .semibold))
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
                            .font(.system(size: 11)).foregroundStyle(.secondary)
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
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 工具与维护

    private var maintenanceSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
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
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("用量导出", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text("按天导出本机已积累的全部来源 Token 与平台费用（CSV，纯本地生成）。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("导出用量 CSV") { exportUsageCSV() }
                        Spacer()
                    }
                    if !usageExportStatus.isEmpty {
                        Text(usageExportStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("脱敏诊断", systemImage: "stethoscope")
                        .font(.system(size: 12, weight: .semibold))
                    Text("导出版本、系统、签名、数据源与工具状态；不包含凭据或会话内容。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("导出诊断信息") { exportDiagnostics() }
                        Spacer()
                    }
                    if !diagnosticStatus.isEmpty {
                        Text(diagnosticStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
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

    private func exportUsageCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出用量 CSV"
        panel.nameFieldStringValue = UsageCSVExport.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UsageCSVExport.makeCSV(HistoryStore.all()).write(
                to: url, atomically: true, encoding: .utf8)
            usageExportStatus = "已导出：\(url.lastPathComponent)"
        } catch {
            usageExportStatus = "导出失败：\(error.localizedDescription)"
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
        zhipuKeyStatus = store.zhipuKeyConfigured
            ? "已配置 \(store.zhipuKeyPreview() ?? "")（\(store.zhipuQuotaDomain.title)）"
            : "未配置（\(store.zhipuQuotaDomain.title)）"
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
                expandBalanceKey = false
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
                expandKimiKey = false
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

    private func saveZhipuKey() {
        let key = zhipuKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            zhipuKeyStatus = CredentialStoreError.emptyCredential.errorDescription ?? "请输入 Key"
            return
        }
        busy = true
        zhipuKeyStatus = "正在验证智谱官方额度…"
        Task {
            do {
                let result = try await ZhipuQuotaService().load(
                    apiKey: key,
                    domain: store.zhipuQuotaDomain
                )
                try store.saveZhipuKey(key)
                zhipuKeyInput = ""
                state.invalidateZhipuQuota()
                state.zhipuQuota.result = result
                let now = Date()
                state.zhipuQuota.loadedAt = now
                state.zhipuQuota.succeededAt = now
                state.zhipuQuota.error = nil
                zhipuKeyStatus = "验证通过，已读取 \(result.windowCount) 个额度窗口"
                expandZhipuKey = false
            } catch {
                zhipuKeyStatus = (error as? ZhipuQuotaError)?.errorDescription
                    ?? (error as? CredentialStoreError)?.errorDescription
                    ?? "智谱 API Key 验证失败"
            }
            busy = false
        }
    }

    private func clearZhipuKey() {
        busy = true
        do {
            try store.clearZhipuKey()
        } catch {
            zhipuKeyStatus = (error as? CredentialStoreError)?.errorDescription
                ?? "智谱 API Key 清除失败"
            busy = false
            return
        }
        zhipuKeyInput = ""
        state.invalidateZhipuQuota()
        zhipuKeyStatus = "已清除智谱 API Key"
        busy = false
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
            expandUsageToken = false
        } else if case .error(let message) = state.usageState {
            usageStatus = "\(prefix)，但用量刷新失败：\(message)"
        }
    }
}

// 账户连接行：整行可点展开/收起；未连接的引导输入，已连接的收起成一行状态。
private struct AccountConnectionRow<Fields: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let configured: Bool
    let statusText: String
    @Binding var expanded: Bool
    let fields: Fields

    init(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        configured: Bool,
        statusText: String,
        expanded: Binding<Bool>,
        @ViewBuilder fields: () -> Fields
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.detail = detail
        self.configured = configured
        self.statusText = statusText
        self._expanded = expanded
        self.fields = fields()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 27, height: 27)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Text(configured ? "已连接" : "未连接")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(configured ? Color.green : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (configured ? Color.green : Color.secondary).opacity(0.12),
                            in: Capsule()
                        )
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(expanded ? "收起输入区" : "展开输入区")

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    fields
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 36)
                .transition(.opacity)
            }
        }
    }
}
