import Foundation

/// Errors shared by demo and live services. Server error codes (BACKEND_CONTRACT §6) map 1:1.
nonisolated enum CrushlyError: Error, Equatable, LocalizedError, Sendable {
    case notAuthenticated
    case invalidInput(String)
    case notFound
    case rateLimited
    case profileIncomplete
    case termsRequired
    case matchingPaused
    case consentStale
    case spaceUnavailable
    case boundaryOutdated
    case insufficientAccuracy
    case staleEvidence
    case staleRequest
    case sessionExpired
    case notParticipating
    case notAvailable
    case alreadySent
    case alreadyMatched
    case limitReached
    case invalidDuration
    case domainNotAllowed
    // Client-side only.
    case locationNotVerified
    case invalidVerificationCode
    case network
    case backendNotConfigured
    case unknown(String)

    init(serverCode: String) {
        switch serverCode {
        case "not_authenticated": self = .notAuthenticated
        case "invalid_input": self = .invalidInput("Please check what you entered.")
        case "not_found": self = .notFound
        case "rate_limited": self = .rateLimited
        case "profile_incomplete": self = .profileIncomplete
        case "terms_required": self = .termsRequired
        case "matching_paused": self = .matchingPaused
        case "consent_stale": self = .consentStale
        case "space_unavailable": self = .spaceUnavailable
        case "boundary_outdated": self = .boundaryOutdated
        case "insufficient_accuracy": self = .insufficientAccuracy
        case "stale_evidence": self = .staleEvidence
        case "stale_request": self = .staleRequest
        case "session_expired": self = .sessionExpired
        case "not_participating": self = .notParticipating
        case "not_available": self = .notAvailable
        case "already_sent": self = .alreadySent
        case "already_matched": self = .alreadyMatched
        case "limit_reached": self = .limitReached
        case "invalid_duration": self = .invalidDuration
        case "domain_not_allowed": self = .domainNotAllowed
        default: self = .unknown(serverCode)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Please sign in again."
        case .invalidInput(let message): message
        case .notFound: "That's no longer available."
        case .rateLimited: "Slow down a little and try again in a moment."
        case .profileIncomplete: "Finish your profile and matching preferences first."
        case .termsRequired: "Please accept the Terms and Privacy Policy."
        case .matchingPaused: "Campus matching is paused."
        case .consentStale: "Something changed. Please choose again."
        case .spaceUnavailable: "This space isn't available for matching right now."
        case .boundaryOutdated: "This space was updated. Please choose again."
        case .insufficientAccuracy, .staleEvidence, .locationNotVerified:
            "Your location couldn't be verified yet. Try again in a moment."
        case .staleRequest: "That request arrived out of order. Trying again."
        case .sessionExpired: "Your matching session ended. Choose again to keep matching here."
        case .notParticipating: "Choose \"Open to matching\" in a campus space first."
        case .notAvailable: "This person isn't available right now."
        case .alreadySent: "You've already shown interest."
        case .alreadyMatched: "You're already matched."
        case .limitReached: "You've used all your interests for this visit."
        case .invalidDuration: "That pause length isn't available."
        case .domainNotAllowed: "Crushly is only open to USC email addresses right now."
        case .invalidVerificationCode: "That code is incorrect or expired."
        case .network: "You appear to be offline. We'll retry when you're back."
        case .backendNotConfigured: "The live backend isn't configured."
        case .unknown(let detail): "Something went wrong (\(detail))."
        }
    }
}
