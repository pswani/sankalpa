import Foundation
import SankalpaCore

/// Turns the service's stable problem `code` back into the app's own `SankalpaCommandError`.
///
/// The service is the authority on whether a command is allowed, but its `detail` strings are
/// written for an API client, not for the person holding the phone. Every refusal the service can
/// make has a domain error here already, with wording the screens have been designed around — so
/// the code is mapped back into that error rather than shown raw.
///
/// Some of those errors carry a value the service does not send back (the earliest allowed start
/// date, the state a sankalpa was in at a past moment). Those come from `Context`: the app already
/// holds the sankalpa the command was about, so it can say the same sentence it always could.
enum ServerRefusal {

    /// What the app knew when it sent the command.
    struct Context {
        var sankalpa: Sankalpa?
        var today: CalendarDay
        /// The state a lifecycle command was trying to reach.
        var target: LifecycleState?
        /// The moment a session command was trying to record.
        var occurredAt: CalendarMoment?
        /// The declaration a declare command was carrying.
        var declaration: Declaration?
    }

    static func commandError(for failure: APIFailure, context: Context) -> SankalpaCommandError {
        guard case .refused(let code, let detail, _) = failure else {
            return .storage(.unavailable(failure.fallbackMessage))
        }

        switch code {
        case "SANKALPA_NOT_FOUND":
            return .sankalpaNotFound(context.sankalpa?.id ?? SankalpaId())

        // MARK: Declaration
        case "INVALID_TITLE":
            let trimmed = context.declaration?.title
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .declaration(.invalidTitle(trimmed.isEmpty ? .blank : .tooLong(max: Title.maxLength)))
        case "INVALID_TIMES_PER_PERIOD":
            return .declaration(.invalidTimesPerPeriod(context.declaration?.timesPerPeriod ?? 0))
        case "INVALID_PERIOD_COUNT":
            return .declaration(.invalidPeriodCount(context.declaration?.periodCount ?? 0))
        case "START_DATE_TOO_FAR_IN_PAST":
            return .declaration(.startDateTooFarInPast(
                earliestAllowed: context.today.addingYears(-Sankalpa.maximumBackdatedStartInYears)
            ))

        // MARK: Lifecycle
        case "INVALID_LIFECYCLE_TRANSITION":
            guard let from = context.sankalpa?.state, let to = context.target else {
                return .storage(.unavailable(detail))
            }
            return .lifecycle(.invalidLifecycleTransition(from: from, to: to))
        case "TRANSITION_IN_FUTURE":
            return .lifecycle(.transitionInFuture)
        case "TRANSITION_BEFORE_START":
            guard let startDate = context.sankalpa?.commitment.startDate else {
                return .storage(.unavailable(detail))
            }
            return .lifecycle(.transitionBeforeStart(startDate: startDate))

        // MARK: Sessions
        case "SESSION_IN_FUTURE":
            return .session(.sessionInFuture)
        case "SESSION_BEFORE_COMMITMENT_START":
            guard let startDate = context.sankalpa?.commitment.startDate else {
                return .storage(.unavailable(detail))
            }
            return .session(.sessionBeforeCommitmentStart(startDate: startDate))
        case "SESSION_AFTER_COMMITMENT_END":
            guard let endDate = context.sankalpa?.commitment.endDate else {
                return .storage(.unavailable(detail))
            }
            return .session(.sessionAfterCommitmentEnd(endDate: endDate))
        case "SANKALPA_NOT_IN_PROGRESS":
            guard let sankalpa = context.sankalpa, let occurredAt = context.occurredAt else {
                return .storage(.unavailable(detail))
            }
            return .session(.sankalpaNotInProgressAtThatTime(
                state: sankalpa.lifecycle.state(at: occurredAt)
            ))

        // MARK: Not a rule the app models
        case "CONCURRENT_MODIFICATION":
            // The app holds a stale copy. It refreshes after every command, so the way out is to
            // look again and retry — which is what this says, in the same voice as the rest.
            return .storage(.unavailable(
                "This sankalpa was changed somewhere else. Pull to refresh, then try again."
            ))
        default:
            // A code this version does not know about. The service's own sentence is better than
            // a generic one, and it is the only thing that can explain an unfamiliar rule.
            return .storage(.unavailable(detail))
        }
    }
}
