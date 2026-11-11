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
        case .meetNow: "Meet Now"
        case .connectLater: "Connect Later"
        case .either: "Either Works"
        }
    }
    var symbol: String {
        switch self {
        case .meetNow: "bolt.heart.fill"
        case .connectLater: "clock.badge.checkmark"
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
    var instagramHandle: String = ""
    var termsAcceptedVersion: String?
    var privacyAcceptedVersion: String?
    var ageConfirmed: Bool = false
    var verifiedOnlyDiscovery: Bool = false

    var hasAcceptedCurrentTerms: Bool {
        ageConfirmed && termsAcceptedVersion == LegalDocuments.termsVersion && privacyAcceptedVersion == LegalDocuments.privacyVersion
    }
}

/// What other users may see. Deliberately has no email, coordinates, timestamps of activity or private fields.
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
    var spaceName: String?
    /// Demo mode only: a clearly simulated distance band. Always nil in live mode.
    var simulatedDistanceBand: String?

    var isPhotoApproved: Bool { photoReviewStatus == .approved }
}

nonisolated enum SpaceKind: String, Codable, Sendable { case place, event }

nonisolated struct CampusSpace: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: SpaceKind
    var subtitle: String
    var startsAt: Date?
    var endsAt: Date?

    var symbol: String {
        switch kind {
        case .place: "building.columns.fill"
        case .event: "party.popper.fill"
        }
    }

    func hasFutureEnd(now: Date) -> Bool { (endsAt ?? .distantPast) > now }
}

nonisolated struct PulseSession: Identifiable, Codable, Equatable, Sendable {
    enum State: Equatable { case live, paused, expired, ended }

    var id: UUID
    var spaceID: UUID
    var availability: Availability
    var startedAt: Date
    var expiresAt: Date
    var pausedAt: Date?
    var endedAt: Date?
    var signalsSent: Int

    func state(at now: Date) -> State {
        if endedAt != nil { return .ended }
        if expiresAt <= now { return .expired }
        if pausedAt != nil { return .paused }
        return .live
    }

    func remaining(at now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }
}

nonisolated struct ShieldState: Codable, Equatable, Sendable {
    var startedAt: Date
    /// nil = until turned off.
    var activeUntil: Date?
    func isActive(at now: Date) -> Bool { activeUntil.map { $0 > now } ?? true }
}

/// Anonymous receipt. The recipient never learns who sent it.
nonisolated struct SignalReceipt: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Rounded down to the server's time bucket.
    var receivedBucket: Date
    /// Only present when the space was crowded enough to not identify anyone.
    var spaceName: String?
}

nonisolated enum SignalStatus: String, Codable, Sendable { case pending, matched, expired, withdrawn }

nonisolated struct SentSignal: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var recipient: PublicProfile
    var createdAt: Date
    var expiresAt: Date
    var status: SignalStatus
}

nonisolated enum SendSignalResult: Equatable, Sendable {
    case sent(remaining: Int)
    case matched(matchID: UUID, remaining: Int)
}

nonisolated enum MatchKind: String, Codable, Sendable {
    case heartSync = "heart_sync"
    case crossedHearts = "crossed_hearts"
    var title: String { self == .heartSync ? "Heart Sync" : "Crossed Hearts" }
}

nonisolated enum ConnectionStatus: String, Codable, Sendable {
    case pendingConfirmation = "pending_confirmation"
    case metTonight = "met_tonight"
    case findLater = "find_later"
    case expired, removed

    var title: String {
        switch self {
        case .pendingConfirmation: "New"
        case .metTonight: "Met Tonight"
        case .findLater: "Find Later"
        case .expired: "Expired"
        case .removed: "Removed"
        }
    }
}

nonisolated struct Connection: Codable, Equatable, Sendable {
    var status: ConnectionStatus
    var confirmBy: Date
    var activeUntil: Date?
    var confirmedAt: Date?
    var lastActivityAt: Date?

    /// The deadline that currently matters for the lifecycle.
    var deadline: Date? {
        switch status {
        case .pendingConfirmation: confirmBy
        case .metTonight, .findLater: activeUntil
        case .expired, .removed: nil
        }
    }
}

nonisolated enum ConnectionActionKind: String, Codable, CaseIterable, Sendable {
    case coffee, studyBreak = "study_break", starter, instagramExchange = "instagram_exchange"
    var title: String {
        switch self {
        case .coffee: "Suggest coffee"
        case .studyBreak: "Suggest a study break"
        case .starter: "Send a conversation starter"
        case .instagramExchange: "Swap Instagram"
        }
    }
    var symbol: String {
        switch self {
        case .coffee: "cup.and.saucer.fill"
        case .studyBreak: "books.vertical.fill"
        case .starter: "text.bubble.fill"
        case .instagramExchange: "camera.circle.fill"
        }
    }
}

nonisolated enum RequestStatus: String, Codable, Sendable {
    case pending, accepted, declined, cancelled
    case timedOut = "timed_out"
    case completed
}

nonisolated struct ConnectionAction: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var actorID: UUID
    var kind: ConnectionActionKind
    var detail: String?
    var status: RequestStatus
    var createdAt: Date
}

nonisolated struct FindRequest: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var requesterID: UUID
    var status: RequestStatus
    var meetingPoint: String
    var respondBy: Date
    var activeUntil: Date?
}

nonisolated struct Match: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: MatchKind
    var createdAt: Date
    var spaceName: String?
    var other: PublicProfile
    var connection: Connection
    var openFind: FindRequest?
    var actions: [ConnectionAction]
}

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

nonisolated struct NotificationPrefs: Codable, Equatable, Sendable {
    var anonymousSignals = true
    var heartSync = true
    var crossedHearts = true
    var findRequests = true
    var connectionReminders = true
    var connectionExpiry = true
    var pulseExpiry = true
    var campusEvents = true
    var signalsMutedUntil: Date?
}

/// Everything needed to hydrate the app after sign-in.
nonisolated struct AccountSnapshot: Equatable, Sendable {
    var userID: UUID
    var email: String
    var profile: Profile?
    var account: PrivateAccount
    var pulse: PulseSession?
    var shield: ShieldState?
    var prefs: NotificationPrefs
    var rules: AppRules
    var serverNow: Date
}
