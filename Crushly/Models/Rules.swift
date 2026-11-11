import Foundation

/// Server-configurable rules (mirrors `app_settings`). Clients display these; only the server enforces them.
nonisolated struct AppRules: Codable, Equatable, Sendable {
    var allowedEmailDomains: [String] = ["usc.edu"]
    var pulseDurationsMinutes: [Int] = [30, 60]
    var signalsPerSession: Int = 5
    var signalValidityHours: Int = 72
    var encounterWindowHours: Int = 24
    var connectionConfirmHours: Int = 24
    var connectionInactiveDays: Int = 7
    var findRequestTimeoutMinutes: Int = 10
    var findActiveMinutes: Int = 30
    /// nil entry = until turned off.
    var shieldDurationsMinutes: [Int?] = [60, 240, 1440, nil]
    var requireOwnPulseToViewAround: Bool = true

    static let `default` = AppRules()

    func isAllowedEmail(_ email: String) -> Bool {
        let parts = email.lowercased().trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return allowedEmailDomains.contains(String(parts[1]))
    }
}

nonisolated enum ProfileRules {
    static let interestCount = 3
    static let maxVibeTags = 5
    static let maxPhotos = 6
    static let promptMaxLength = 160
    static let firstNameMaxLength = 30

    static let interestSuggestions = [
        "Music", "Film", "Late-night food", "Games", "Design", "Coffee", "Photography", "Concerts",
        "Hiking", "Startups", "Tennis", "Dance", "Thrifting", "Basketball", "Cooking", "Poetry",
        "Anime", "Running", "Art museums", "Theater", "Surfing", "Climbing", "Podcasts", "Volunteering"
    ]

    static let vibeSuggestions = [
        "Golden retriever energy", "Quietly funny", "Night owl", "Early riser", "Main character",
        "Deep talks", "Spontaneous", "Planner", "Bookish", "Chaotic good", "Soft-spoken", "Social butterfly"
    ]
}

nonisolated enum ProfilePrompts {
    static let all = [
        "My ideal study break is…",
        "You'll find me on campus at…",
        "The way to my heart is…",
        "A green flag I look for…",
        "My most controversial food take…",
        "Let's debate…"
    ]
}

nonisolated enum ConversationStarters {
    static let all = [
        "What's the best thing you've eaten near campus?",
        "What song is on repeat for you right now?",
        "Settle this: Leavey or Doheny?",
        "What's something you're weirdly good at?"
    ]
}

nonisolated enum MeetingPoints {
    static let presets = [
        "Tommy Trojan",
        "USC Village fountain",
        "Leavey Library entrance",
        "Tutor Campus Center lobby",
        "Doheny Library steps"
    ]
}

nonisolated enum LegalDocuments {
    /// Bump when the real documents change; users must re-accept.
    static let termsVersion = "dev-2026-11"
    static let privacyVersion = "dev-2026-11"
    /// True until real legal text replaces the development placeholders.
    static let isPlaceholder = true
}
