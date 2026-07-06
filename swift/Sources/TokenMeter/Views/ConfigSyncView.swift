import SwiftUI

// 配置同步面板：列出本机各 Agent 工具的 MCP/指令现状，选真源 → 勾选目标 →
// 预览（开独立窗口看结构化 diff）→ 确认写入。数据来自 agentsync CLI 子进程。
// 面板宽 420，重内容（完整 diff/确认）走 ConfigSyncWindow 独立窗口。
struct ConfigSyncView: View {
    @EnvironmentObject var state: AppState
    var onSettings: () -> Void

    @State private var source: String = ""              // 真源工具 key
    @State private var selectedTargets: Set<String> = []  // 推送目标
    @State private var layerMCP = true
    @State private var layerRules = false
    @State private var busy = false
    @State private var actionError: String?

    private var profiles: [ConfigProfile] {
        state.configSync.result?.profiles ?? []
    }

    // 可作为真源/目标的工具：有 MCP 配置或有指令文件
    private var syncable: [ConfigProfile] {
        profiles.filter { $0.mcpState == "present" || $0.hasRules }
    }

    private var layers: [String] {
        var l: [String] = []
        if layerMCP { l.append("mcp") }
        if layerRules { l.append("rules") }
        return l
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if !profiles.isEmpty {
                    sourceCard
                    toolsCard
                    layerCard
                    actionBar
                    if let err = actionError {
                        Text(err).font(.system(size: 11)).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                } else if state.configSync.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let err = state.configSync.error {
                    Text(err).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.top, 60)
                } else {
                    Text("未检测到 agentsync 命令")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task { await state.loadConfigSync() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text("配置同步")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            iconButton("arrow.clockwise") { Task { await state.loadConfigSync(force: true) } }
            iconButton("gearshape") { onSettings() }
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - 真源选择
    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("真源（从哪个工具抽取）", systemImage: "star")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $source) {
                    Text("请选择").tag("")
                    ForEach(syncable) { p in
                        Text(p.label).tag(p.key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - 工具列表（勾选推送目标）
    private var toolsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("推送目标（勾选）", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(profiles) { p in
                    toolRow(p)
                    if p.id != profiles.last?.id { Divider().opacity(0.3) }
                }
            }
        }
    }

    private func toolRow(_ p: ConfigProfile) -> some View {
        let isSource = p.key == source
        let selectable = (p.mcpState == "present" || p.hasRules) && !isSource
        return HStack(spacing: 8) {
            Image(systemName: iconFor(p.key))
                .font(.system(size: 13))
                .foregroundStyle(isSource ? Theme.brand : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.label).font(.system(size: 12, weight: .medium))
                Text("MCP \(p.mcpDisplay) · 指令 \(p.hasRules ? "✓" : "—")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if isSource {
                Text("真源").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            } else {
                Toggle("", isOn: Binding(
                    get: { selectedTargets.contains(p.key) },
                    set: { on in
                        if on { selectedTargets.insert(p.key) }
                        else { selectedTargets.remove(p.key) }
                    }
                ))
                .labelsHidden()
                .disabled(!selectable)
            }
        }
        .opacity(selectable || isSource ? 1 : 0.45)
    }

    private func iconFor(_ key: String) -> String {
        if key.hasPrefix("claude") { return "sparkles" }
        if key.hasPrefix("codex") { return "chevron.left.forwardslash.chevron.right" }
        if key.hasPrefix("cursor") { return "cursorarrow" }
        if key.hasPrefix("trae") { return "t.square" }
        if key.hasPrefix("qoder") { return "q.square" }
        if key.hasPrefix("cline") { return "terminal" }
        return "app.dashed"
    }

    // MARK: - 层选择
    private var layerCard: some View {
        Card {
            HStack(spacing: 16) {
                Label("同步层", systemImage: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("MCP", isOn: $layerMCP).font(.system(size: 11))
                Toggle("指令", isOn: $layerRules).font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
        }
    }

    // MARK: - 操作
    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await doPull() }
            } label: {
                Label("拉取真源", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 12))
            }
            .disabled(source.isEmpty || layers.isEmpty || busy)

            Spacer()

            Button {
                openPreview()
            } label: {
                Label("预览并推送", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedTargets.isEmpty || layers.isEmpty || busy)
        }
    }

    private func doPull() async {
        guard !source.isEmpty else { return }
        busy = true; actionError = nil
        do {
            _ = try await state.configSyncPull(from: source, layers: layers)
        } catch {
            actionError = (error as? AgentSyncError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }

    private func openPreview() {
        actionError = nil
        ConfigSyncWindow.shared.present(
            targets: Array(selectedTargets),
            layers: layers,
            state: state
        )
    }
}
