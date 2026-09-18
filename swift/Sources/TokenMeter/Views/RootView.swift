import SwiftUI

enum AppView: Equatable {
    case dashboard
    case source(Provider)
    case settings
    case detail(String)   // model key: "flash" | "pro"
}

// 可从首页内容区进入的工具详情；它不再承担导航栏职责。
enum Provider: String, CaseIterable, Identifiable {
    case deepseek = "DeepSeek"
    case claude = "Claude"
    case codex = "Codex"
    case kimi = "Kimi Code"
    case opencode = "OpenCode"
    case gemini = "Gemini"
    case copilot = "Copilot"
    case qwen = "Qwen Code"
    case cursor = "Cursor"
    var id: String { rawValue }

    // 没装对应工具就不显示该 tab
    var available: Bool {
        switch self {
        case .deepseek: return true
        case .claude: return ClaudeUsage.isAvailable
        case .codex: return CodexUsage.isAvailable
        case .kimi: return KimiUsage.isAvailable
        case .opencode: return OpenCodeUsage.isAvailable
        case .gemini: return GeminiUsage.isAvailable
        case .copilot: return CopilotUsage.isAvailable
        case .qwen: return QwenCodeUsage.isAvailable
        case .cursor: return CursorUsage.isAvailable
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var view: AppView = .dashboard
    @State private var historyRange = UsageHistoryRange(
        rawValue: ConfigStore.shared.overviewHistoryRangeDays
    ) ?? .month

    // Coding 来源是否进入聚合只由用户开关决定；当前数据路径消失时仍保留
    // 已积累的历史。首页明细再按所选范围 Token > 0 过滤零用量来源。
    private var sources: [Provider] {
        Provider.allCases.filter { p in
            switch p {
            case .deepseek: return state.deepseekEnabled
            case .claude: return state.claudeEnabled
            case .codex: return state.codexEnabled
            case .kimi: return state.kimiEnabled
            case .opencode: return state.opencodeEnabled
            case .gemini: return state.geminiEnabled
            case .copilot: return state.copilotEnabled
            case .qwen: return state.qwenEnabled
            case .cursor: return state.cursorEnabled
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 首页只有一层时间目录，工具在正文中平铺。
            if view == .dashboard {
                rangeBar
            }
            Group {
                switch view {
                case .dashboard:
                    OverviewView(
                        range: historyRange,
                        sources: sources,
                        onOpenSource: { view = .source($0) },
                        onSettings: { view = .settings }
                    )
                case .source(let provider):
                    let back = { view = AppView.dashboard }
                    switch provider {
                        case .deepseek:
                            DashboardView(
                                onBack: back,
                                onSettings: { view = .settings },
                                onDetail: { key in view = .detail(key) })
                        case .claude:
                            ClaudeView(onBack: back, onSettings: { view = .settings })
                        case .codex:
                            CodexView(onBack: back, onSettings: { view = .settings })
                        case .kimi:
                            KimiView(onBack: back, onSettings: { view = .settings })
                        case .opencode:
                            OpenCodeView(onBack: back, onSettings: { view = .settings })
                        case .gemini:
                            GeminiView(onBack: back, onSettings: { view = .settings })
                        case .copilot:
                            CopilotView(onBack: back, onSettings: { view = .settings })
                        case .qwen:
                            QwenCodeView(onBack: back, onSettings: { view = .settings })
                        case .cursor:
                            CursorView(onBack: back, onSettings: { view = .settings })
                    }
                case .settings:
                    SettingsView(
                        onBack: { view = .dashboard }
                    )
                case .detail(let key):
                    ModelDetailView(modelKey: key, onBack: { view = .source(.deepseek) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Theme.panelWidth, height: Theme.panelHeight, alignment: .top)
        .background(.regularMaterial)
        // 详情对应来源被关闭时直接回首页；本地数据路径暂时消失不抹掉历史入口。
        .onChange(of: sources) { _, newSources in
            if case .source(let provider) = view, !newSources.contains(provider) {
                view = .dashboard
            }
        }
    }

    private var rangeBar: some View {
        HStack(spacing: 6) {
            ForEach(UsageHistoryRange.allCases) { range in
                Button {
                    historyRange = range
                    ConfigStore.shared.overviewHistoryRangeDays = range.rawValue
                } label: {
                    Text(range.tabTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(historyRange == range ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            historyRange == range ? Theme.brand : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TokenMeter.Range.\(range.tabTitle)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}
