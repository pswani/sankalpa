import Foundation

/// The six requirement states. The transition table below is domain logic and lives here rather
/// than in a view or a query (DD-4).
public enum LifecycleState: String, CaseIterable, Codable, Sendable {
    case notStarted
    case inProgress
    case paused
    case completedSuccessfully
    case completedUnsuccessfully
    case stopped

    public var displayName: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .paused: return "Paused"
        case .completedSuccessfully: return "Completed successfully"
        case .completedUnsuccessfully: return "Completed unsuccessfully"
        case .stopped: return "Stopped"
        }
    }

    /// A shorter label for badges and list rows, where the full name would wrap.
    public var badgeText: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .paused: return "Paused"
        case .completedSuccessfully: return "Successful"
        case .completedUnsuccessfully: return "Unsuccessful"
        case .stopped: return "Stopped"
        }
    }

    /// S7 — Completed (either outcome) and Stopped are terminal.
    public var isTerminal: Bool {
        switch self {
        case .completedSuccessfully, .completedUnsuccessfully, .stopped: return true
        case .notStarted, .inProgress, .paused: return false
        }
    }

    public var isActive: Bool {
        self == .inProgress || self == .paused
    }

    public func canTransition(to target: LifecycleState) -> Bool {
        guard self != target else { return false }
        switch self {
        case .notStarted:
            // Not started → Paused is explicitly not a legal transition.
            return target != .paused
        case .inProgress:
            return target != .notStarted
        case .paused:
            return target != .notStarted
        case .completedSuccessfully, .completedUnsuccessfully, .stopped:
            return false
        }
    }

    public var allowedTargets: [LifecycleState] {
        LifecycleState.allCases.filter { canTransition(to: $0) }
    }
}

/// The user, not the system, decides which way a sankalpa completed.
public enum CompletionOutcome: String, CaseIterable, Codable, Sendable {
    case successfully
    case unsuccessfully

    public var state: LifecycleState {
        self == .successfully ? .completedSuccessfully : .completedUnsuccessfully
    }
}
