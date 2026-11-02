import Foundation

enum AppView: Equatable {
    case dashboard
    case source(Provider)
    case settings
    case detail(String)
    case codingModel(HistorySource, String)
    case skill(PersonalSkillRankings.Entry, HistorySource?, [HistorySource])
}

// Keep the settings return route separate from the current route. Entering the
// same settings page again must not erase its origin, and disabling a source
// while there must never return to a now-disabled dashboard.
struct DashboardNavigation: Equatable {
    private(set) var current: AppView = .dashboard
    private(set) var settingsOrigin: AppView = .dashboard

    mutating func open(_ next: AppView) {
        if next == .settings, current != .settings { settingsOrigin = current }
        current = next
    }

    mutating func leaveSettings(enabledProviders: Set<Provider>) {
        if case .source(let provider) = settingsOrigin,
           !enabledProviders.contains(provider) {
            current = .dashboard
        } else {
            current = settingsOrigin
        }
    }
}

// Product identity is shared by navigation, source metadata and refresh plans.
// It does not describe a particular SwiftUI view or client shape.
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

    var available: Bool {
        SourceCatalog.descriptor(for: SourceCatalog.source(for: self)).isAvailable()
    }
}
