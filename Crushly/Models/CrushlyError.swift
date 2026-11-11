import Foundation

/// Errors shared by demo and live services. Server error codes (BACKEND_CONTRACT §5) map 1:1.
nonisolated enum CrushlyError: Error, Equatable, LocalizedError, Sendable {
    case notAuthenticated
    case profileIncomplete
    case termsRequired
    case domainNotAllowed
    case noLiveSession
    case sessionExpired
    case shielded
    case notAvailable
    case selfSignal
    case limitReached
    case alreadySignaled
    case alreadyMatched
    case invalidDuration
    case invalidCode
    case invalidInput(String)
    case notFound
    case notPermitted
    case requestExpired
    case invalidVerificationCode
    case network
    case backendNotConfigured
    case unknown(String)

    init(serverCode: String) {
        switch serverCode {
        case "not_authenticated": self = .notAuthenticated
        case "profile_incomplete": self = .profileIncomplete
        case "terms_required": self = .termsRequired
        case "domain_not_allowed": self = .domainNotAllowed
        case "no_live_session": self = .noLiveSession
        case "session_expired": self = .sessionExpired
        case "shielded": self = .shielded
        case "not_available": self = .notAvailable
        case "self_signal": self = .selfSignal
        case "limit_reached": self = .limitReached
        case "already_signaled": self = .alreadySignaled
        case "already_matched": self = .alreadyMatched
        case "invalid_duration": self = .invalidDuration
        case "invalid_code": self = .invalidCode
        case "invalid_input": self = .invalidInput("Please check the highlighted fields.")
        case "not_found": self = .notFound
        case "not_permitted": self = .notPermitted
        case "request_expired": self = .requestExpired
        default: self = .unknown(serverCode)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Please sign in again."
        case .profileIncomplete: "Finish your profile first."
        case .termsRequired: "Please accept the Terms and Privacy Policy."
        case .domainNotAllowed: "Crushly is only open to USC email addresses right now."
        case .noLiveSession: "Enter the Radius to do that."
        case .sessionExpired: "Your Pulse session has ended. Start a new one."
        case .shielded: "You're in Protect My Heart mode."
        case .notAvailable: "This person isn't available right now."
        case .selfSignal: "You can't signal yourself."
        case .limitReached: "You've used all your Heart Signals for this session."
        case .alreadySignaled: "You've already sent them a Heart Signal."
        case .alreadyMatched: "You're already connected."
        case .invalidDuration: "That session length isn't available."
        case .invalidCode: "That event code didn't work."
        case .invalidInput(let message): message
        case .notFound: "That's no longer available."
        case .notPermitted: "You can't do that."
        case .requestExpired: "That request has expired."
        case .invalidVerificationCode: "That code is incorrect or expired."
        case .network: "You appear to be offline. We'll retry when you're back."
        case .backendNotConfigured: "The live backend isn't configured."
        case .unknown(let detail): "Something went wrong (\(detail))."
        }
    }
}
