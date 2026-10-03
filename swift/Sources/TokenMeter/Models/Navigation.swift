import Foundation

enum AppView: Equatable {
    case dashboard
    case source(Provider)
    case settings
    case detail(String)
    case codingModel(HistorySource, String)
    case skill(PersonalSkillRankings.Entry, HistorySource?, [HistorySource])
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
