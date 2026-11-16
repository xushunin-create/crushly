import Foundation

// Wire formats for the RPCs in docs/BACKEND_CONTRACT.md. Property names match SQL names exactly.
// Map into domain models immediately; nothing outside Services/Live uses these types.

nonisolated struct ProfileDTO: Codable, Sendable {
    var id: UUID
    var first_name: String?
    var age: Int?
    var pronouns: String?
    var gender: String?
    var interests: [String]?
    var vibe_tags: [String]?
    var prompt_question: String?
    var prompt_answer: String?
    var intention: Intention?
    var availability: Availability?
    var photo_paths: [String]?
    var photo_review_status: ReviewStatus?
    var selfie_status: SelfieStatus?
    var university_domain: String?

    init(_ p: Profile) {
        id = p.id; first_name = p.firstName; age = p.age; pronouns = p.pronouns; gender = p.gender
        interests = p.interests; vibe_tags = p.vibeTags; prompt_question = p.promptQuestion
        prompt_answer = p.promptAnswer; intention = p.intention; availability = p.availability
        photo_paths = p.photoPaths
        // Server-only fields are never sent.
        photo_review_status = nil; selfie_status = nil; university_domain = nil
    }

    var domain: Profile {
        Profile(
            id: id, firstName: first_name ?? "", age: age ?? 18, pronouns: pronouns ?? "", gender: gender ?? "",
            interests: interests ?? [], vibeTags: vibe_tags ?? [], promptQuestion: prompt_question ?? ProfilePrompts.all[0],
            promptAnswer: prompt_answer ?? "", intention: intention ?? .figuringItOut, availability: availability ?? .either,
            photoPaths: photo_paths ?? [], photoReviewStatus: photo_review_status ?? .pending,
            selfieStatus: selfie_status ?? .notStarted, universityDomain: university_domain ?? ""
        )
    }
}

nonisolated struct PrivateDTO: Decodable, Sendable {
    var age_confirmed_at: Date?
    var terms_version: String?
    var privacy_version: String?
    var verified_only_discovery: Bool?
    var match_gender: String?
    var show_me: [String]?
    var age_min: Int?
    var age_max: Int?

    var account: PrivateAccount {
        PrivateAccount(termsAcceptedVersion: terms_version, privacyAcceptedVersion: privacy_version,
                       ageConfirmed: age_confirmed_at != nil, verifiedOnlyDiscovery: verified_only_discovery ?? false)
    }

    var preferences: MatchPreferences {
        MatchPreferences(matchGender: match_gender.flatMap(MatchGender.init(rawValue:)),
                         showMe: Set((show_me ?? []).compactMap(MatchGender.init(rawValue:))),
                         ageMin: age_min ?? MatchPreferences.ageFloor,
                         ageMax: age_max ?? MatchPreferences.ageCeilingStored)
    }
}

nonisolated struct PrefsDTO: Codable, Sendable {
    var new_matches: Bool?
    var messages: Bool?

    init(_ p: NotificationPrefs) { new_matches = p.newMatches; messages = p.messages }

    var domain: NotificationPrefs {
        NotificationPrefs(newMatches: new_matches ?? true, messages: messages ?? true)
    }
}

/// `app_settings` rows folded into an object keyed by setting name.
nonisolated struct SettingsDTO: Decodable, Sendable {
    var allowed_email_domains: [String]?
    var participation_lease_seconds: Int?
    var evidence_max_accuracy_m: Double?
    var evidence_max_fix_age_seconds: Double?
    var evidence_stationary_max_fix_age_seconds: Double?
    var allow_draft_spaces: Bool?
    var discovery_min_participants: Int?
    var discovery_max_results: Int?
    var interests_per_session: Int?
    var pause_durations_minutes: [Int]?
    var message_max_chars: Int?

    var domain: AppRules {
        var rules = AppRules.default
        if let v = allowed_email_domains { rules.allowedEmailDomains = v }
        if let v = participation_lease_seconds { rules.participationLeaseSeconds = v }
        if let v = evidence_max_accuracy_m { rules.evidenceMaxAccuracyMeters = v }
        if let v = evidence_max_fix_age_seconds { rules.evidenceMaxFixAgeSeconds = v }
        if let v = evidence_stationary_max_fix_age_seconds { rules.evidenceStationaryMaxFixAgeSeconds = v }
        if let v = allow_draft_spaces { rules.allowDraftSpaces = v }
        if let v = discovery_min_participants { rules.discoveryMinParticipants = v }
        if let v = discovery_max_results { rules.discoveryMaxResults = v }
        if let v = interests_per_session { rules.interestsPerSession = v }
        if let v = pause_durations_minutes { rules.pauseDurationsMinutes = v }
        if let v = message_max_chars { rules.messageMaxChars = v }
        return rules
    }
}

nonisolated struct StateDTO: Decodable, Sendable {
    var profile: ProfileDTO?
    var privateAccount: PrivateDTO?
    var prefs: PrefsDTO?
    var settings: SettingsDTO?
    var serverNow: Date?

    enum CodingKeys: String, CodingKey {
        case profile, prefs, settings
        case privateAccount = "private"
        case serverNow = "now"
    }
}

nonisolated struct PublicProfileDTO: Decodable, Sendable {
    var id: UUID
    var first_name: String?
    var age: Int?
    var pronouns: String?
    var gender: String?
    var interests: [String]?
    var vibe_tags: [String]?
    var prompt_question: String?
    var prompt_answer: String?
    var intention: Intention?
    var availability: Availability?
    var photo_paths: [String]?
    var photo_review_status: ReviewStatus?

    var domain: PublicProfile {
        PublicProfile(
            id: id, firstName: first_name ?? "Someone", age: age ?? 18, pronouns: pronouns ?? "", gender: gender ?? "",
            interests: interests ?? [], vibeTags: vibe_tags ?? [], promptQuestion: prompt_question ?? "",
            promptAnswer: prompt_answer ?? "", intention: intention ?? .figuringItOut, availability: availability ?? .either,
            photoPaths: photo_paths ?? [], photoReviewStatus: photo_review_status ?? .pending
        )
    }
}

// MARK: Participation

/// The evidence object the participation RPCs expect. No coordinates, by construction.
nonisolated struct EvidenceDTO: Encodable, Sendable {
    var fix_ts_ms: Int64
    var fix_age_ms: Int64
    var horizontal_accuracy_m: Double
    var stationary: Bool

    init(_ e: LocationEvidence) {
        fix_ts_ms = Int64((e.fixTimestamp.timeIntervalSince1970 * 1000).rounded())
        fix_age_ms = Int64(max(0, e.fixAge * 1000).rounded())
        horizontal_accuracy_m = e.horizontalAccuracy
        stationary = e.stationary
    }
}

nonisolated struct ParticipationDTO: Decodable, Sendable {
    nonisolated struct Session: Decodable, Sendable {
        var id: UUID
        var space_slug: String?
        var boundary_version: Int
        var lease_expires_at: Date
        var last_seq: Int64
    }
    var now: Date
    var consent_epoch: Int64
    var matching_paused: Bool
    var paused_until: Date?
    var session: Session?

    var domain: ParticipationStatus {
        ParticipationStatus(
            serverNow: now, consentEpoch: consent_epoch, matchingPaused: matching_paused, pausedUntil: paused_until,
            session: session.map { ParticipationSession(id: $0.id, spaceSlug: $0.space_slug, boundaryVersion: $0.boundary_version,
                                                        leaseExpiresAt: $0.lease_expires_at, lastSeq: $0.last_seq) })
    }
}

nonisolated struct LeaseDTO: Decodable, Sendable {
    var session_id: UUID
    var lease_expires_at: Date
    var now: Date
    var domain: ParticipationLease { ParticipationLease(sessionID: session_id, leaseExpiresAt: lease_expires_at, serverNow: now) }
}

nonisolated struct DiscoveryDTO: Decodable, Sendable {
    var status: String
    var profiles: [PublicProfileDTO]
    var domain: DiscoveryResult {
        status == "quiet" ? .quiet : .candidates(profiles.map(\.domain))
    }
}

nonisolated struct InterestDTO: Decodable, Sendable {
    var result: String
    var match_id: UUID?
    var remaining: Int
    var domain: InterestResult {
        if result == "matched", let id = match_id { return .matched(matchID: id, remaining: remaining) }
        return .sent(remaining: remaining)
    }
}

// MARK: Conversations

nonisolated struct ConversationDTO: Decodable, Sendable {
    var match_id: UUID
    var created_at: Date
    var other: PublicProfileDTO
    var last_message_at: Date?
    var last_message_preview: String?
    var last_message_from_me: Bool?
    var unread: Bool?

    var domain: Conversation {
        Conversation(id: match_id, createdAt: created_at, other: other.domain, lastMessageAt: last_message_at,
                     lastMessagePreview: last_message_preview, lastMessageFromMe: last_message_from_me, unread: unread ?? false)
    }
}

nonisolated struct MessageDTO: Decodable, Sendable {
    var id: UUID
    var sender_is_me: Bool
    var body: String
    /// Kept at full microsecond precision: it is half of the keyset cursor.
    var created_at: Date

    private enum CodingKeys: String, CodingKey { case id, sender_is_me, body, created_at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sender_is_me = try c.decode(Bool.self, forKey: .sender_is_me)
        body = try c.decode(String.self, forKey: .body)
        let raw = try c.decode(String.self, forKey: .created_at)
        guard let date = PreciseTimestamp.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .created_at, in: c, debugDescription: "Bad timestamp")
        }
        created_at = date
    }

    var domain: ChatMessage { ChatMessage(id: id, senderIsMe: sender_is_me, body: body, createdAt: created_at) }
}

/// Postgres timestamps carry microseconds; the SDK's default date coding keeps only milliseconds, which would make a
/// keyset cursor skip messages sent within the same millisecond. A Double holds today's epoch to ~0.24 µs, so
/// rounding to the nearest microsecond recovers the exact server value.
nonisolated enum PreciseTimestamp {
    static func parse(_ string: String) -> Date? {
        var main = string
        var fraction = 0.0
        if let dot = string.firstIndex(of: ".") {
            let afterDot = string[string.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            main = String(string[..<dot]) + afterDot.dropFirst(digits.count)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let base = formatter.date(from: main) { return base.addingTimeInterval(fraction) }
        // Postgres may print a bare "+00" offset.
        if main.range(of: #"[+-]\d\d$"#, options: .regularExpression) != nil, let base = formatter.date(from: main + ":00") {
            return base.addingTimeInterval(fraction)
        }
        return nil
    }

    static func format(_ date: Date) -> String {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        let seconds = (micros / 1_000_000).rounded(.down)
        let fraction = Int(micros - seconds * 1_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let base = formatter.string(from: Date(timeIntervalSince1970: seconds))   // …:SSZ
        return String(base.dropLast()) + String(format: ".%06dZ", fraction)
    }
}

nonisolated struct SentMessageDTO: Decodable, Sendable {
    var id: UUID
    var created_at: Date
}
