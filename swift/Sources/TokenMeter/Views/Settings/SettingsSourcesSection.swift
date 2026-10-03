import SwiftUI

struct SettingsSourcesSection: View {
    @EnvironmentObject var state: AppState
    private var codingProviders: [Provider] {
        SourceCatalog.codingAgentSources.map(SourceCatalog.provider(for:))
    }

    // MARK: - 数据来源

    private var availableCodingProviders: [Provider] {
        codingProviders.filter(\.available)
    }

    private var unavailableCodingProviders: [Provider] {
        codingProviders.filter { !$0.available }
    }

    var body: some View {
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
                Divider().padding(.vertical, 7)
                codexLiveQuotaToggle
            }
        }
    }

    private var codexLiveQuotaToggle: some View {
        Toggle(isOn: Binding(
            get: { state.codexLiveQuotaEnabled },
            set: { state.setCodexLiveQuotaEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex 官方实时配额")
                    .font(.system(size: 12, weight: .semibold))
                Text("默认关闭。开启后读取本机 Codex 登录态并请求 ChatGPT 官方接口；本地用量统计始终只读会话文件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("TokenMeter.Settings.CodexLiveQuota")
        .disabled(!state.codexEnabled)
        .padding(.vertical, 7)
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
        case .codex: return "本地 session 用量与配额快照"
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


}
