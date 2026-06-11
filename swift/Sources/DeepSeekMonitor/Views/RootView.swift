import SwiftUI

enum AppView: Equatable {
    case dashboard
    case settings
    case detail(String)   // model key: "flash" | "pro"
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var view: AppView = .dashboard

    var body: some View {
        Group {
            switch view {
            case .dashboard:
                DashboardView(
                    onSettings: { view = .settings },
                    onDetail: { key in view = .detail(key) })
            case .settings:
                SettingsView(onBack: { view = .dashboard })
            case .detail(let key):
                ModelDetailView(modelKey: key, onBack: { view = .dashboard })
            }
        }
        .frame(width: Theme.panelWidth, height: Theme.panelHeight)
        .background(.regularMaterial)
    }
}
