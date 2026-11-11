import Foundation

// Wire formats for the RPCs in docs/BACKEND_CONTRACT.md. Property names match SQL column names exactly.
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
    var instagram_handle: String?
    var age_confirmed_at: Date?
    var terms_version: String?
    var privacy_version: String?
    var verified_only_discovery: Bool?

    var domain: PrivateAccount {
        PrivateAccount(instagramHandle: instagram_handle ?? "", termsAcceptedVersion: terms_version,
                       privacyAcceptedVersion: privacy_version, ageConfirmed: age_confirmed_at != nil,
                       verifiedOnlyDiscovery: verified_only_discovery ?? false)
    }
}

nonisolated struct SessionDTO: Decodable, Sendable {
    var id: UUID
    var space_id: UUID
    var availability: Availability
    var started_at: Date
    var expires_at: Date
    var paused_at: Date?
    var ended_at: Date?
    var signals_sent: Int

    var domain: PulseSession {
        PulseSession(id: id, spaceID: space_id, availability: availability, startedAt: started_at, expiresAt: expires_at,
                     pausedAt: paused_at, endedAt: ended_at, signalsSent: signals_sent)
    }
}

nonisolated struct ShieldDTO: Decodable, Sendable {
    var started_at: Date
    var active_until: Date?
    var domain: ShieldState { ShieldState(startedAt: started_at, activeUntil: active_until) }
}

nonisolated struct PrefsDTO: Codable, Sendable {
    var anonymous_signals: Bool?
    var heart_sync: Bool?
    var crossed_hearts: Bool?
    var find_requests: Bool?
    var connection_reminders: Bool?
    var connection_expiry: Bool?
    var pulse_expiry: Bool?
    var campus_events: Bool?
    var signals_muted_until: Date?

    init(_ p: NotificationPrefs) {
        anonymous_signals = p.anonymousSignals; heart_sync = p.heartSync; crossed_hearts = p.crossedHearts
        find_requests = p.findRequests; connection_reminders = p.connectionReminders; connection_expiry = p.connectionExpiry
        pulse_expiry = p.pulseExpiry; campus_events = p.campusEvents; signals_muted_until = p.signalsMutedUntil
    }

    var domain: NotificationPrefs {
        NotificationPrefs(anonymousSignals: anonymous_signals ?? true, heartSync: heart_sync ?? true,
                          crossedHearts: crossed_hearts ?? true, findRequests: find_requests ?? true,
                          connectionReminders: connection_reminders ?? true, connectionExpiry: connection_expiry ?? true,
                          pulseExpiry: pulse_expiry ?? true, campusEvents: campus_events ?? true,
                          signalsMutedUntil: signals_muted_until)
    }
}

/// `app_settings` rows folded into an object keyed by setting name.
nonisolated struct SettingsDTO: Decodable, Sendable {
    var allowed_email_domains: [String]?
    var pulse_durations_minutes: [Int]?
    var signals_per_session: Int?
    var signal_validity_hours: Int?
    var encounter_window_hours: Int?
    var connection_confirm_hours: Int?
    var connection_inactive_days: Int?
    var find_request_timeout_minutes: Int?
    var find_active_minutes: Int?
    var shield_durations_minutes: [Int]?
    var require_own_pulse_to_view_around: Bool?

    var domain: AppRules {
        var rules = AppRules.default
        if let v = allowed_email_domains { rules.allowedEmailDomains = v }
        if let v = pulse_durations_minutes { rules.pulseDurationsMinutes = v }
        if let v = signals_per_session { rules.signalsPerSession = v }
        if let v = signal_validity_hours { rules.signalValidityHours = v }
        if let v = encounter_window_hours { rules.encounterWindowHours = v }
        if let v = connection_confirm_hours { rules.connectionConfirmHours = v }
        if let v = connection_inactive_days { rules.connectionInactiveDays = v }
        if let v = find_request_timeout_minutes { rules.findRequestTimeoutMinutes = v }
        if let v = find_active_minutes { rules.findActiveMinutes = v }
        if let v = shield_durations_minutes { rules.shieldDurationsMinutes = v.map { Optional($0) } + [nil] }
        if let v = require_own_pulse_to_view_around { rules.requireOwnPulseToViewAround = v }
        return rules
    }
}

nonisolated struct StateDTO: Decodable, Sendable {
    var profile: ProfileDTO?
    var privateAccount: PrivateDTO?
    var pulse: SessionDTO?
    var shield: ShieldDTO?
    var prefs: PrefsDTO?
    var settings: SettingsDTO?
    var serverNow: Date?

    enum CodingKeys: String, CodingKey {
        case profile, pulse, shield, prefs, settings
        case privateAccount = "private"
        case serverNow = "now"
    }
}

nonisolated struct SpaceDTO: Decodable, Sendable {
    var id: UUID
    var name: String
    var kind: SpaceKind
    var subtitle: String?
    var starts_at: Date?
    var ends_at: Date?
    var domain: CampusSpace {
        CampusSpace(id: id, name: name, kind: kind, subtitle: subtitle ?? "", startsAt: starts_at, endsAt: ends_at)
    }
}

nonisolated struct PublicProfileDTO: Decodable, Sendable {
    var id: UUID
    var first_name: String
    var age: Int
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
    var space_name: String?

    var domain: PublicProfile {
        PublicProfile(
            id: id, firstName: first_name, age: age, pronouns: pronouns ?? "", gender: gender ?? "",
            interests: interests ?? [], vibeTags: vibe_tags ?? [], promptQuestion: prompt_question ?? "",
            promptAnswer: prompt_answer ?? "", intention: intention ?? .figuringItOut, availability: availability ?? .either,
            photoPaths: photo_paths ?? [], photoReviewStatus: photo_review_status ?? .pending, spaceName: space_name,
            simulatedDistanceBand: nil
        )
    }
}

nonisolated struct ReceiptDTO: Decodable, Sendable {
    var id: UUID
    var received_bucket: Date
    var space_name: String?
}

nonisolated struct SentSignalDTO: Decodable, Sendable {
    var id: UUID
    var recipient: PublicProfileDTO
    var created_at: Date
    var expires_at: Date
    var status: SignalStatus
}

nonisolated struct ConnectionDTO: Decodable, Sendable {
    var status: ConnectionStatus
    var confirm_by: Date
    var active_until: Date?
    var confirmed_at: Date?
    var last_activity_at: Date?
    var domain: Connection {
        Connection(status: status, confirmBy: confirm_by, activeUntil: active_until, confirmedAt: confirmed_at,
                   lastActivityAt: last_activity_at)
    }
}

nonisolated struct FindDTO: Decodable, Sendable {
    var id: UUID
    var requester_id: UUID
    var status: RequestStatus
    var meeting_point: String?
    var respond_by: Date
    var active_until: Date?
    var domain: FindRequest {
        FindRequest(id: id, requesterID: requester_id, status: status, meetingPoint: meeting_point ?? "",
                    respondBy: respond_by, activeUntil: active_until)
    }
}

nonisolated struct ActionDTO: Decodable, Sendable {
    struct Payload: Decodable, Sendable { var detail: String? }
    var id: UUID
    var actor_id: UUID
    var kind: ConnectionActionKind
    var payload: Payload?
    var status: RequestStatus
    var created_at: Date
    var domain: ConnectionAction {
        ConnectionAction(id: id, actorID: actor_id, kind: kind, detail: payload?.detail, status: status, createdAt: created_at)
    }
}

nonisolated struct MatchDTO: Decodable, Sendable {
    var match_id: UUID
    var kind: MatchKind
    var created_at: Date
    var space_name: String?
    var other: PublicProfileDTO
    var connection: ConnectionDTO
    var open_find: FindDTO?
    var actions: [ActionDTO]?

    var domain: Match {
        Match(id: match_id, kind: kind, createdAt: created_at, spaceName: space_name, other: other.domain,
              connection: connection.domain, openFind: open_find?.domain, actions: (actions ?? []).map(\.domain))
    }
}
