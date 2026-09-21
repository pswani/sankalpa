import Foundation

/// How the period the user is living in right now is going. Derived like any other period outcome,
/// but kept separate because an open window is not yet satisfied or missed.
public struct CurrentPeriodProgress: Hashable, Sendable {
    public let window: PeriodWindow
    public let required: Int
    public let performed: Int

    public init(window: PeriodWindow, required: Int, performed: Int) {
        self.window = window
        self.required = required
        self.performed = performed
    }

    public var remaining: Int { max(0, required - performed) }
    public var isSatisfied: Bool { performed >= required }
    public var fraction: Double {
        guard required > 0 else { return 1 }
        return min(1, Double(performed) / Double(required))
    }

    /// Whether more sessions were performed than the commitment asks for. Legitimate — the number
    /// of times is a minimum — but it needs different wording, because "3 of 2" reads like a fault.
    public var exceededCommitment: Bool { performed > required }

    /// "1 of 2 today", or "3 today · 2 committed" once the minimum is passed.
    public var progressPhrase: String {
        exceededCommitment
            ? "\(performed) \(window.unit.currentPeriodPhrase) · \(required) committed"
            : "\(performed) of \(required) \(window.unit.currentPeriodPhrase)"
    }

    /// The same thing where the period is already named by a heading: "1 of 2 sessions".
    public var sessionCountPhrase: String {
        exceededCommitment
            ? "\(performed) sessions · \(required) committed"
            : "\(performed) of \(required) sessions"
    }

    /// "1 more to go today"
    public var remainingPhrase: String {
        "\(remaining) more to go \(window.unit.currentPeriodPhrase)"
    }
}

/// A row in the Sankalpas list.
public struct SankalpaSummary: Identifiable, Hashable, Sendable {
    public let sankalpa: Sankalpa
    public let currentPeriod: CurrentPeriodProgress?
    public let totalSessions: Int

    public var id: SankalpaId { sankalpa.id }
    public var title: String { sankalpa.title.value }
    public var state: LifecycleState { sankalpa.state }
    public var actionType: ActionType { sankalpa.actionType }
    public var commitment: Commitment { sankalpa.commitment }

    public init(sankalpa: Sankalpa, currentPeriod: CurrentPeriodProgress?, totalSessions: Int) {
        self.sankalpa = sankalpa
        self.currentPeriod = currentPeriod
        self.totalSessions = totalSessions
    }
}

/// Counts of how closed periods turned out. Counts only — the requirements deliberately do not ask
/// for streaks, scores or a progress percentage (01-strategic-design).
public struct PeriodTally: Hashable, Sendable {
    public let satisfied: Int
    public let unsatisfied: Int
    public let paused: Int

    public init(satisfied: Int, unsatisfied: Int, paused: Int) {
        self.satisfied = satisfied
        self.unsatisfied = unsatisfied
        self.paused = paused
    }

    public var evaluated: Int { satisfied + unsatisfied }
    public var isEmpty: Bool { satisfied == 0 && unsatisfied == 0 && paused == 0 }

    public init(outcomes: [PeriodOutcome]) {
        self.init(
            satisfied: outcomes.count { $0.standing == .satisfied },
            unsatisfied: outcomes.count { $0.standing == .unsatisfied },
            paused: outcomes.count { $0.standing == .paused }
        )
    }
}

/// One entry in the cross-sankalpa journal of performed sessions.
public struct JournalEntry: Identifiable, Hashable, Sendable {
    public let session: Session
    public let sankalpaTitle: String
    public let actionType: ActionType

    public var id: SessionId { session.id }
    public var occurredAt: CalendarMoment { session.occurredAt }

    public init(session: Session, sankalpaTitle: String, actionType: ActionType) {
        self.session = session
        self.sankalpaTitle = sankalpaTitle
        self.actionType = actionType
    }
}
