import Foundation

// Domain types shared by every feature. Backend DTOs are mapped into these in Services/Live;
// nothing outside Services/ should know about Supabase types.

nonisolated enum Availability: String, Codable, CaseIterable, Identifiable, Sendable {
    case meetNow = "meet_now"
    case connectLater = "connect_later"
    case either

    var id: String { rawValue }
    var title: String {
        switch self {
        case .meetNow: "Up for meeting soon"
        case .connectLater: "Prefer to chat first"
        case .either: "Either works"
        }
    }
    var symbol: String {
        switch self {
        case .meetNow: "cup.and.saucer.fill"
        case .connectLater: "text.bubble.fill"
        case .either: "sparkles"
        }
    }
}

nonisolated enum Intention: String, Codable, CaseIterable, Identifiable, Sendable {
    case somethingSerious = "something_serious"
    case somethingCasual = "something_casual"
    case newFriends = "new_friends"
    case figuringItOut = "figuring_it_out"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .somethingSerious: "Something serious"
        case .somethingCasual: "Something casual"
        case .newFriends: "New friends"
        case .figuringItOut: "Figuring it out"
        }
    }
}

nonisolated enum ReviewStatus: String, Codable, Sendable {
    case pending, approved, rejected
}

nonisolated enum SelfieStatus: String, Codable, Sendable {
    case notStarted = "not_started", pending, verified, rejected
}

/// The signed-in user's own profile (editable).
nonisolated struct Profile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var firstName: String = ""
    var age: Int = 18
    var pronouns: String = ""
    var gender: String = ""
    var interests: [String] = []
    var vibeTags: [String] = []
    var promptQuestion: String = ProfilePrompts.all[0]
    var promptAnswer: String = ""
    var intention: Intention = .figuringItOut
    var availability: Availability = .either
    var photoPaths: [String] = []
    var photoReviewStatus: ReviewStatus = .pending
    var selfieStatus: SelfieStatus = .notStarted
    var universityDomain: String = "usc.edu"

    var missingFields: [String] {
        var missing: [String] = []
        if firstName.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("First name") }
        if age < 18 { missing.append("Age (18+)") }
        if interests.count != ProfileRules.interestCount { missing.append("Exactly \(ProfileRules.interestCount) interests") }
        if promptAnswer.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("Prompt answer") }
        if photoPaths.isEmpty { missing.append("At least one photo") }
        return missing
    }
    var isComplete: Bool { missingFields.isEmpty }
}

/// Private account fields. Never shown to others.
nonisolated struct PrivateAccount: Codable, Equatable, Sendable {
    var termsAcceptedVersion: String?
    var privacyAcceptedVersion: String?
    var ageConfirmed: Bool = false
    var verifiedOnlyDiscovery: Bool = false

    var hasAcceptedCurrentTerms: Bool {
        ageConfirmed && termsAcceptedVersion == LegalDocuments.termsVersion && privacyAcceptedVersion == LegalDocuments.privacyVersion
    }
}

/// Gender values used for matching (server: `profile_private.match_gender` / `show_me`).
nonisolated enum MatchGender: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case woman, man, nonbinary

    var id: String { rawValue }
    var title: String {
        switch self {
        case .woman: "Woman"
        case .man: "Man"
        case .nonbinary: "Nonbinary"
        }
    }
    var plural: String {
        switch self {
        case .woman: "Women"
        case .man: "Men"
        case .nonbinary: "Nonbinary people"
        }
    }

    static func < (a: MatchGender, b: MatchGender) -> Bool { a.rawValue < b.rawValue }
}

/// Private matching preferences, enforced in both directions on the server (`can_match`). Never shown to others.
nonisolated struct MatchPreferences: Codable, Equatable, Sendable {
    static let ageFloor = 18
    /// The editor's top value; it means "and older", stored as the server maximum.
    static let ageCeilingShown = 60
    static let ageCeilingStored = 120

    var matchGender: MatchGender?
    var showMe: Set<MatchGender> = []
    var ageMin: Int = ageFloor
    var ageMax: Int = ageCeilingStored

    var isComplete: Bool {
        matchGender != nil && !showMe.isEmpty && Self.ageFloor <= ageMin && ageMin <= ageMax && ageMax <= Self.ageCeilingStored
    }

    var missingFields: [String] {
        var missing: [String] = []
        if matchGender == nil { missing.append("Match me as") }
        if showMe.isEmpty { missing.append("Show me") }
        return missing
    }
}

/// What other users may see. Deliberately has no email, location, space, timestamps of activity or private fields.
nonisolated struct PublicProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var firstName: String
    var age: Int
    var pronouns: String
    var gender: String
    var interests: [String]
    var vibeTags: [String]
    var promptQuestion: String
    var promptAnswer: String
    var intention: Intention
    var availability: Availability
    var photoPaths: [String]
    var photoReviewStatus: ReviewStatus

    var isPhotoApproved: Bool { photoReviewStatus == .approved }
}

// MARK: - Participation (BACKEND_CONTRACT §4 "Participation")

/// The caller's own live session, as the server reports it. Only ever about the signed-in user.
nonisolated struct ParticipationSession: Equatable, Sendable {
    var id: UUID
    var spaceSlug: String?
    var boundaryVersion: Int
    var leaseExpiresAt: Date
    var lastSeq: Int64
}

/// `my_participation()`: the source of truth for reconciliation on launch and foreground.
nonisolated struct ParticipationStatus: Equatable, Sendable {
    var serverNow: Date
    var consentEpoch: Int64
    var matchingPaused: Bool
    var pausedUntil: Date?
    var session: ParticipationSession?
}

/// Result of `open_participation` / `renew_participation`.
nonisolated struct ParticipationLease: Equatable, Sendable {
    var sessionID: UUID
    var leaseExpiresAt: Date
    var serverNow: Date
}

// MARK: - Discovery and interest

nonisolated enum DiscoveryResult: Equatable, Sendable {
    /// Too few people are participating here. Deliberately carries no count.
    case quiet
    case candidates([PublicProfile])
}

nonisolated enum InterestResult: Equatable, Sendable {
    case sent(remaining: Int)
    case matched(matchID: UUID, remaining: Int)
}

// MARK: - Conversations

/// One active match. Stores no place and no time other than when the match (and last message) happened.
nonisolated struct Conversation: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID          // match id
    var createdAt: Date
    var other: PublicProfile
    var lastMessageAt: Date?
    var lastMessagePreview: String?
    var lastMessageFromMe: Bool?
    var unread: Bool
}

nonisolated struct ChatMessage: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var senderIsMe: Bool
    var body: String
    var createdAt: Date
}

/// Keyset cursor for `fetch_messages`: both parts or neither.
nonisolated struct MessageCursor: Equatable, Sendable {
    var createdAt: Date
    var id: UUID
}

nonisolated struct SentMessageReceipt: Equatable, Sendable {
    var id: UUID
    var createdAt: Date
}

// MARK: - Safety

nonisolated struct BlockedUser: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var firstName: String
    var blockedAt: Date
}

nonisolated enum ReportCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case harassment, fakeProfile = "fake_profile", under18 = "under_18", unsafeBehavior = "unsafe_behavior"
    case hateSpeech = "hate_speech", spam, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .harassment: "Harassment"
        case .fakeProfile: "Fake Profile"
        case .under18: "Under 18"
        case .unsafeBehavior: "Unsafe Behavior"
        case .hateSpeech: "Hate Speech"
        case .spam: "Spam"
        case .other: "Other"
        }
    }
}

/// Server keys `new_matches`, `messages`.
nonisolated struct NotificationPrefs: Codable, Equatable, Sendable {
    var newMatches = true
    var messages = true
}

/// Everything needed to hydrate the app after sign-in.
nonisolated struct AccountSnapshot: Equatable, Sendable {
    var userID: UUID
    var email: String
    var profile: Profile?
    var account: PrivateAccount
    var preferences: MatchPreferences
    var prefs: NotificationPrefs
    var rules: AppRules
    var serverNow: Date
}
