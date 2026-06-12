import SwiftUI

enum AppView: Equatable {
    case dashboard
    case settings
    case detail(String)   // model key: "flash" | "pro"
}

// 顶部切换的监控源；后续加新工具在这里扩 case
enum Provider: String, CaseIterable, Identifiable {
    case deepseek = "DeepSeek"
    case codex = "Codex"
    var id: String { rawValue }

    // 没装对应工具就不显示该 tab
    var available: Bool {
        switch self {
        case .deepseek: return true
        case .codex: return CodexUsage.isAvailable
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var view: AppView = .dashboard
    @State private var provider: Provider = .deepseek

    private var tabs: [Provider] { Provider.allCases.filter(\.available) }

    var body: some View {
        VStack(spacing: 0) {
            // 设置/详情页占满面板，切换栏只在监控主页显示
            if view == .dashboard, tabs.count > 1 {
                providerBar
            }
            Group {
                switch view {
                case .dashboard:
                    switch provider {
                    case .deepseek:
                        DashboardView(
                            onSettings: { view = .settings },
                            onDetail: { key in view = .detail(key) })
                    case .codex:
                        CodexView()
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
