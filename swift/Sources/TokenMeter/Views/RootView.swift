import SwiftUI

enum AppView: Equatable {
    case dashboard
    case settings
    case detail(String)   // model key: "flash" | "pro"
}

// 顶部切换的监控源；后续加新工具在这里扩 case
enum Provider: String, CaseIterable, Identifiable {
    case overview = "总览"
    case deepseek = "DeepSeek"
    case claude = "Claude"
    case codex = "Codex"
    case cursor = "Cursor"
    var id: String { rawValue }

    // 没装对应工具就不显示该 tab
    var available: Bool {
        switch self {
        case .overview: return true
        case .deepseek: return true
        case .claude: return ClaudeUsage.isAvailable
        case .codex: return CodexUsage.isAvailable
        case .cursor: return CursorUsage.isAvailable
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var view: AppView = .dashboard
    @State private var provider: Provider = .overview

    // 已安装且在设置里开启监控的源
    private var tabs: [Provider] {
        Provider.allCases.filter { p in
            guard p.available else { return false }
            switch p {
            case .overview: return true
            case .deepseek: return state.deepseekEnabled
            case .claude: return state.claudeEnabled
            case .codex: return state.codexEnabled
            case .cursor: return state.cursorEnabled
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 设置/详情页占满面板，切换栏只在监控主页显示
            if view == .dashboard, tabs.count > 1 {
                providerBar
            }
            Group {
                switch view {
                case .dashboard:
                    if tabs.isEmpty {
                        allDisabledPlaceholder
                    } else {
                        switch provider {
                        case .overview:
                            OverviewView(onSettings: { view = .settings })
                        case .deepseek:
                            DashboardView(
                                onSettings: { view = .settings },
                                onDetail: { key in view = .detail(key) })
                        case .claude:
                            ClaudeView(onSettings: { view = .settings })
                        case .codex:
                            CodexView(onSettings: { view = .settings })
                        case .cursor:
                            CursorView(onSettings: { view = .settings })
                        }
                    }
                case .settings:
                    SettingsView(onBack: { view = .dashboard })
                case .detail(let key):
                    ModelDetailView(modelKey: key, onBack: { view = .dashboard })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Theme.panelWidth, height: Theme.panelHeight, alignment: .top)
        .background(.regularMaterial)
        // 当前 tab 被关闭时跳到第一个可用 tab
        .onChange(of: tabs) { _, newTabs in
            if !newTabs.contains(provider), let first = newTabs.first {
                provider = first
            }
        }
        .onAppear {
            if !tabs.contains(provider), let first = tabs.first {
                provider = first
            }
        }
    }

    private var allDisabledPlaceholder: some View {
        VStack(spacing: 12) {
            Text("所有监控源已关闭")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("打开设置") { view = .settings }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var providerBar: some View {
        Picker("", selection: $provider) {
            ForEach(tabs) { p in
                Text(p.rawValue).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}
