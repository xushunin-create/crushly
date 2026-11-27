import Foundation

/// Server-configurable rules (mirrors `app_settings`, BACKEND_CONTRACT §1). Clients display these and use them to
/// avoid pointless requests; only the server enforces them.
nonisolated struct AppRules: Codable, Equatable, Sendable {
    var allowedEmailDomains: [String] = ["usc.edu"]
    var participationLeaseSeconds: Int = 60
    var evidenceMaxAccuracyMeters: Double = 30
    var evidenceMaxFixAgeSeconds: Double = 15
    var evidenceStationaryMaxFixAgeSeconds: Double = 300
    /// Dev/staging only. Production must keep this false (see docs/PRE_LAUNCH_CHECKLIST.md).
    var allowDraftSpaces: Bool = false
    var discoveryMinParticipants: Int = 2
    var discoveryMaxResults: Int = 8
    var interestsPerSession: Int = 5
    /// Offered pause lengths in minutes. "Until I turn it back on" is always offered as well.
    var pauseDurationsMinutes: [Int] = [60, 240, 1440]
    var messageMaxChars: Int = 2000

    static let `default` = AppRules()

    func isAllowedEmail(_ email: String) -> Bool {
        let parts = email.lowercased().trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return allowedEmailDomains.contains(String(parts[1]))
    }

    /// The on-device membership thresholds that must agree with the server's evidence checks.
    var membershipConfig: MembershipConfig {
        var config = MembershipConfig.standard
        config.maxAccuracy = evidenceMaxAccuracyMeters
        config.maxEvidenceAge = evidenceMaxFixAgeSeconds
        config.stationaryReuseMax = evidenceStationaryMaxFixAgeSeconds
        return config
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

nonisolated enum LegalDocuments {
    /// Bump whenever terms.md / privacy.md change in substance; users must re-accept.
    static let termsVersion = "2026-11-16"
    static let privacyVersion = "2026-11-16"

    enum Kind: String, Identifiable, Sendable {
        case terms = "Terms of Service", privacy = "Privacy Policy"
        var id: String { rawValue }
        var resource: String { self == .terms ? "terms" : "privacy" }
        var version: String { self == .terms ? LegalDocuments.termsVersion : LegalDocuments.privacyVersion }
    }

    /// The bundled Markdown text (Resources/Legal/*.md), or nil if it's missing from the build.
    static func text(_ kind: Kind, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: kind.resource, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// True while either document is missing or still has `[[FILL-IN]]` markers awaiting the operator and legal
    /// review. Shown as a warning on the document screens; must be false before launch.
    static var isPlaceholder: Bool {
        [Kind.terms, .privacy].contains { text($0).map { $0.contains("[[") } ?? true }
    }
}
