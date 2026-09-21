import Foundation

/// Every business refusal in the domain. Domain errors carry no transport or presentation concern;
/// adapters decide how to show them (06-hexagonal-architecture).
public protocol DomainError: Error, Equatable, Sendable {
    /// A short, non-technical sentence suitable for showing to the single user of this app.
    var message: String { get }
}

public enum TitleProblem: Equatable, Sendable {
    case blank
    case tooLong(max: Int)
}

public enum DeclarationError: DomainError {
    case invalidTitle(TitleProblem)
    case invalidTimesPerPeriod(Int)
    case invalidPeriodCount(Int)
    case startDateTooFarInPast(earliestAllowed: CalendarDay)

    public var message: String {
        switch self {
        case .invalidTitle(.blank):
            return "Give the sankalpa a title."
        case .invalidTitle(.tooLong(let max)):
            return "Keep the title to \(max) characters or fewer."
        case .invalidTimesPerPeriod(let value):
            return value < 1
                ? "Commit to at least one session per period."
                : "\(TimesPerPeriod.maxValue) times per period is the most that can be committed to."
        case .invalidPeriodCount(let value):
            return value < 1
                ? "A duration must be at least one whole period."
                : "A duration cannot be longer than \(PeriodCount.maxValue) periods."
        case .startDateTooFarInPast(let earliest):
            return "The start date cannot be earlier than \(earliest.longDisplayText) — a sankalpa may start at most one year in the past."
        }
    }
}

public enum LifecycleTransitionError: DomainError {
    case invalidLifecycleTransition(from: LifecycleState, to: LifecycleState)
    case transitionInFuture
    case transitionBeforeStart(startDate: CalendarDay)
    /// The change would land before one already recorded. The transition itself is legal; the
    /// clock is the problem.
    case transitionOutOfOrder(lastRecorded: CalendarMoment)

    public var message: String {
        switch self {
        case .invalidLifecycleTransition(let from, let to):
            return "A sankalpa that is \(from.displayName) cannot move to \(to.displayName)."
        case .transitionInFuture:
            return "A lifecycle change cannot take effect in the future."
        case .transitionBeforeStart(let startDate):
            return "A sankalpa cannot begin before its start date, \(startDate.longDisplayText)."
        case .transitionOutOfOrder(let lastRecorded):
            return "This device's clock reads earlier than the last change to this sankalpa, which was \(lastRecorded.day.longDisplayText). Check the date and time, then try again."
        }
    }
}

public enum SessionNotLoggable: DomainError {
    case sessionInFuture
    case sessionBeforeCommitmentStart(startDate: CalendarDay)
    case sessionAfterCommitmentEnd(endDate: CalendarDay)
    case sankalpaNotInProgressAtThatTime(state: LifecycleState)

    public var message: String {
        switch self {
        case .sessionInFuture:
            return "Only a session you have already performed can be logged."
        case .sessionBeforeCommitmentStart(let startDate):
            return "This sankalpa starts on \(startDate.longDisplayText). Nothing can be logged before then."
        case .sessionAfterCommitmentEnd(let endDate):
            return "This sankalpa ended on \(endDate.longDisplayText). Nothing can be logged after then."
        case .sankalpaNotInProgressAtThatTime(let state):
            return "The sankalpa was \(state.displayName) at that time, so no session can be recorded for it."
        }
    }
}
