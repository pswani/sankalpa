import Foundation

/// Everything a command can refuse with. The application layer adds only the one failure the
/// domain cannot see — that the sankalpa is not there.
public enum SankalpaCommandError: Error, Equatable, Sendable {
    case sankalpaNotFound(SankalpaId)
    case sessionNotFound(SessionId)
    case declaration(DeclarationError)
    case lifecycle(LifecycleTransitionError)
    case session(SessionNotLoggable)
    case storage(PersistenceError)

    public var message: String {
        switch self {
        case .sankalpaNotFound:
            return "That sankalpa is no longer available."
        case .sessionNotFound:
            return "That session is no longer there, so there was nothing to take back."
        case .declaration(let error):
            return error.message
        case .lifecycle(let error):
            return error.message
        case .session(let error):
            return error.message
        case .storage(let error):
            return error.message
        }
    }
}
