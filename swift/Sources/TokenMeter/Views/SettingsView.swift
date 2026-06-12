import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void

    private let store = ConfigStore.shared
    @State private var apiKeyInput = ""
    @State private var apiStatus = ""
    @State private var usageTokenInput = ""
    @State private var usageStatus = ""
    @State private var showManualPaste = false
    @State private var busy = false
    @State private var syncing = false
    @State private var autostartOn = false
    @State private var autoUpdateOn = true

    @StateObject private var sync = LoginSyncController()
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                monitorSection
                sectionTitle("DeepSeek 凭据", hint: "仅 DeepSeek 监控使用，其他监控源无需配置")
                apiKeySection
                usageTokenSection
                refreshSection
                autostartSection
                updateSection
                footer
            }
            .padding(14)
        }
        .onAppear { reloadStatus() }
        .onReceive(sync.$captured.compactMap { $0 }) { _ in
            syncing = false
            usageStatus = "已通过网页登录自动同步，正在刷新…"
            Task { await refreshUsageAfterToken("已自动同步用量 Token") }
        }
        .onReceive(sync.$ended) { ended in
            if ended {
                syncing = false
                usageStatus = "登录窗口已关闭，未获取到 Token。可重新同步或手动粘贴。"
            }
        }
    }

    // 设置页内分组标题：把 DeepSeek 专属凭据与通用设置区分开
    private func sectionTitle(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .bold))
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Text("设置").font(.system(size: 15, weight: .bold))
            Spacer()
        }
    }

    // MARK: - 监控源开关
    private var monitorSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("监控源", systemImage: "switch.2").font(.system(size: 12, weight: .semibold))
                Text("关闭后隐藏对应面板，且不再发起查询/扫描。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("DeepSeek（余额 + 模型用量）", isOn: Binding(
                    get: { state.deepseekEnabled },
                    set: { state.setDeepseekEnabled($0) }))
                Toggle("Claude（本地 transcript 用量）", isOn: Binding(
                    get: { state.claudeEnabled },
                    set: { state.setClaudeEnabled($0) }))
                    .disabled(!ClaudeUsage.isAvailable)
                if !ClaudeUsage.isAvailable {
                    Text("未检测到 Claude 本地数据（~/.claude/projects），开关不生效。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                // 日用量预警：超阈值菜单栏图标变橙，超 1.5 倍变红；0 = 不预警。
                // 标签独立成行：内联 label 会被 5 个 segment 挤成竖排
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude 日用量预警（菜单栏图标变色）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { state.claudeDailyLimitM },
                        set: { state.setClaudeDailyLimit($0) })) {
                        Text("关").tag(0)
                        Text("100M").tag(100)
                        Text("300M").tag(300)
                        Text("500M").tag(500)
                        Text("1000M").tag(1000)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                .disabled(!state.claudeEnabled || !ClaudeUsage.isAvailable)
                Toggle("Codex（本地 session 用量 + 配额）", isOn: Binding(
                    get: { state.codexEnabled },
                    set: { state.setCodexEnabled($0) }))
                    .disabled(!CodexUsage.isAvailable)
                if !CodexUsage.isAvailable {
                    Text("未检测到 Codex 本地数据（~/.codex/sessions），开关不生效。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Toggle("Cursor（账户用量，经 cursor.com 查询）", isOn: Binding(
                    get: { state.cursorEnabled },
                    set: { state.setCursorEnabled($0) }))
                    .disabled(!CursorUsage.isAvailable)
                if !CursorUsage.isAvailable {
                    Text("未检测到 Cursor 安装（无 state.vscdb），开关不生效。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("菜单栏图标旁显示（今日合计 = Claude + Codex 本地统计）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { state.menubarInfoMode },
                        set: { state.setMenubarInfoMode($0) })) {
                        Text("不显示").tag("off")
                        Text("今日合计").tag("total")
                        Text("Claude").tag("claude")
                        Text("Codex 配额").tag("codex")
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
        }
    }

    // MARK: - API Key
    private var apiKeySection: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("DeepSeek API Key", systemImage: "key").font(.system(size: 12, weight: .semibold))
                Text("用于查询账户余额。只保存在本机 Keychain。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("sk-...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存并验证") { saveApiKey() }.disabled(busy || apiKeyInput.isEmpty)
                    Button("清除") { clearApiKey() }.disabled(busy)
                    Spacer()
                }
                if !apiStatus.isEmpty {
                    Text(apiStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    // MARK: - 用量 Token
    private var usageTokenSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("DeepSeek 用量 Token", systemImage: "chart.bar.doc.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                Text("用于查询用量与消费（DeepSeek 官方未开放用量 API，需网页登录 token）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(syncing ? "登录窗口处理中…" : "方式一：网页登录自动同步") {
                    startSync()
                }.disabled(syncing)
                Button(showManualPaste ? "收起手动粘贴" : "方式二：手动粘贴 token") {
                    showManualPaste.toggle()
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.brand)
                if showManualPaste {
                    Text("浏览器控制台执行 JSON.parse(localStorage.userToken).value 复制结果")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    SecureField("粘贴 token", text: $usageTokenInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存") { saveUsageToken() }.disabled(busy || usageTokenInput.isEmpty)
                        Button("清除") { clearUsageToken() }.disabled(busy)
                        Spacer()
                    }
                }
                if !usageStatus.isEmpty {
                    Text(usageStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    // MARK: - 刷新间隔 + 自动刷新
    private var refreshSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("自动刷新", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                Toggle("启用自动刷新", isOn: Binding(
                    get: { state.autoRefreshEnabled },
                    set: { state.setAutoRefresh($0) }))
                Picker("间隔", selection: Binding(
                    get: { state.refreshIntervalSeconds },
                    set: { state.setRefreshInterval($0) })) {
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("30 分钟").tag(1800)
                    Text("1 小时").tag(3600)
                }.pickerStyle(.segmented).disabled(!state.autoRefreshEnabled)
            }
        }
    }

    private var autostartSection: some View {
        Card {
            Toggle(isOn: Binding(
                get: { autostartOn },
                set: { enabled in
                    // 调系统 API 后用真实状态回写本地 state，UI 随之刷新；
                    // 失败时 apply 返回当前真实状态，开关不会停在错误位置。
                    autostartOn = Autostart.apply(enabled)
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("开机自启", systemImage: "power").font(.system(size: 12, weight: .semibold))
                    Text("登录 macOS 时自动启动").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 软件更新
    private var updateSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("软件更新", systemImage: "arrow.down.circle")
                    .font(.system(size: 12, weight: .semibold))
                Toggle("自动检查更新（每日一次）", isOn: Binding(
                    get: { autoUpdateOn },
                    set: { v in
                        ConfigStore.shared.autoUpdateCheckEnabled = v
                        autoUpdateOn = v
                    }))
                HStack {
                    Button(updateButtonTitle) { updateAction() }
                        .disabled(updateBusy)
                    Spacer()
                }
                if !updateStatusText.isEmpty {
                    Text(updateStatusText)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
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
        case .available(let v): return "下载并更新到 v\(v)"
        default: return "检查更新"
        }
    }

    private var updateStatusText: String {
        switch updater.phase {
        case .upToDate: return "已是最新版本 v\(Updater.currentVersion)"
        case .available(let v): return "发现新版本 v\(v)，更新完成后应用会自动重启"
        case .failed(let msg): return msg
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

    private var footer: some View {
        Text("TokenMeter v\(Updater.currentVersion) · 凭据存于本机 Keychain")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Actions
    private func reloadStatus() {
        apiStatus = store.apiKeyConfigured ? "已配置 \(store.apiKeyPreview() ?? "")" : "未配置 API Key"
        usageStatus = store.usageTokenConfigured ? "用量 Token 已配置" : "未配置用量 Token"
        autostartOn = Autostart.isEnabled
        autoUpdateOn = ConfigStore.shared.autoUpdateCheckEnabled
    }

    private func saveApiKey() {
        busy = true
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        store.credApiKey = key
        apiKeyInput = ""
        apiStatus = "已保存，正在验证…"
        Task {
            do {
                let b = try await DeepSeekAPI.fetchBalance(apiKey: key)
                apiStatus = "验证通过，当前余额 \(b.symbol)\(b.totalBalance)\(b.isAvailable ? "" : "（余额不足）")"
                await state.loadBalance()
            } catch {
                apiStatus = (error as? APIError)?.errorDescription ?? "保存或验证失败"
            }
            busy = false
        }
    }

    private func clearApiKey() {
        store.credApiKey = nil
        apiKeyInput = ""
        apiStatus = "已清除 API Key"
        Task { await state.loadBalance() }
    }

    private func startSync() {
        syncing = true
        usageStatus = "正在打开登录窗口…"
        let synced = sync.start()
        if !synced {
            usageStatus = "登录完成后，再次点击同步即可（可多点几次）"
        }
        // 2.5s 后恢复可点，允许反复触发
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { syncing = false }
    }

    private func saveUsageToken() {
        busy = true
        let token = usageTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        store.credUsageToken = token
        usageTokenInput = ""
        usageStatus = "已保存，正在验证用量 Token…"
        Task {
            await refreshUsageAfterToken("手动 Token 已保存")
            busy = false
        }
    }

    private func clearUsageToken() {
        store.credUsageToken = nil
        usageTokenInput = ""
        usageStatus = "已清除用量 Token"
        state.clearUsage()
    }

    private func refreshUsageAfterToken(_ prefix: String) async {
        await state.loadUsage()
        if case .ok = state.usageState, let u = state.usage {
            usageStatus = "\(prefix)，本月消费 \(Fmt.money(u.monthCost))"
        } else if case .error(let m) = state.usageState {
            usageStatus = "\(prefix)，但用量刷新失败：\(m)"
        }
    }
}
