import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

/// The service decides what is allowed; these say the app can still explain the answer in its own
/// words. Every refusal the service documents has a domain error here, and the screens were
/// designed around those errors' wording — a raw `detail` string in an alert would be a regression
/// even when it is accurate.
@Suite("Server refusals")
struct ServerRefusalTests {

    private let today = day(2026, 9, 10)

    private func sankalpa(
        state: LifecycleState = .inProgress,
        start: CalendarDay = day(2026, 9, 1),
        periodCount: Int? = 30
    ) -> Sankalpa {
        Sankalpa.rehydrate(
            id: SankalpaId(),
            declaredAt: CalendarMoment(day: start, hour: 6),
            title: try! Title("Vipassana"),
            description: SankalpaDescription(""),
            actionType: .meditation,
            commitment: Commitment(
                startDate: start,
                periodUnit: .day,
                timesPerPeriod: try! TimesPerPeriod(2),
                periodCount: periodCount.map { try! PeriodCount($0) }
            ),
            lifecycle: LifecycleTimeline(
                current: state,
                transitions: [
                    LifecycleTransition(
                        from: .notStarted, to: .inProgress,
                        effectiveAt: CalendarMoment(day: start, hour: 6),
                        recordedAt: CalendarMoment(day: start, hour: 6)
                    )
                ]
            )
        )
    }

    private func map(
        _ code: String,
        detail: String = "The service said no.",
        context: ServerRefusal.Context
    ) -> SankalpaCommandError {
        ServerRefusal.commandError(
            for: .refused(code: code, detail: detail, status: 422), context: context
        )
    }

    // MARK: - Sessions

    @Test("A session in the future comes back as the app's own refusal")
    func sessionInFuture() {
        let error = map("SESSION_IN_FUTURE", context: .init(today: today))
        #expect(error == .session(.sessionInFuture))
    }

    /// The service says only "before the commitment start"; the sentence the app shows names the
    /// date, which it takes from the sankalpa it already holds.
    @Test("A session before the start names the start date")
    func sessionBeforeStart() {
        let subject = sankalpa()
        let error = map(
            "SESSION_BEFORE_COMMITMENT_START",
            context: .init(sankalpa: subject, today: today)
        )

        #expect(error == .session(.sessionBeforeCommitmentStart(startDate: day(2026, 9, 1))))
        #expect(error.message.contains("September 1, 2026"))
    }

    @Test("A session after the end names the derived end date")
    func sessionAfterEnd() {
        let subject = sankalpa()
        let error = map(
            "SESSION_AFTER_COMMITMENT_END",
            context: .init(sankalpa: subject, today: today)
        )

        #expect(error == .session(.sessionAfterCommitmentEnd(endDate: day(2026, 9, 30))))
    }

    /// The app can say *which* state it was in, because it holds the transition history the
    /// service does not repeat in the error.
    @Test("A session while not in progress names the state at that moment")
    func notInProgressAtThatTime() {
        let paused = Sankalpa.rehydrate(
            id: SankalpaId(),
            declaredAt: CalendarMoment(day: day(2026, 9, 1), hour: 6),
            title: try! Title("Vipassana"),
            description: SankalpaDescription(""),
            actionType: .meditation,
            commitment: Commitment(
                startDate: day(2026, 9, 1), periodUnit: .day,
                timesPerPeriod: try! TimesPerPeriod(1), periodCount: try! PeriodCount(30)
            ),
            lifecycle: LifecycleTimeline(
                current: .paused,
                transitions: [
                    LifecycleTransition(
                        from: .notStarted, to: .inProgress,
                        effectiveAt: CalendarMoment(day: day(2026, 9, 1), hour: 6),
                        recordedAt: CalendarMoment(day: day(2026, 9, 1), hour: 6)
                    ),
                    LifecycleTransition(
                        from: .inProgress, to: .paused,
                        effectiveAt: CalendarMoment(day: day(2026, 9, 5), hour: 8),
                        recordedAt: CalendarMoment(day: day(2026, 9, 5), hour: 8)
                    )
                ]
            )
        )

        let error = map(
            "SANKALPA_NOT_IN_PROGRESS",
            context: .init(
                sankalpa: paused, today: today,
                occurredAt: CalendarMoment(day: day(2026, 9, 7), hour: 9)
            )
        )

        #expect(error == .session(.sankalpaNotInProgressAtThatTime(state: .paused)))
    }

    // MARK: - Lifecycle

    @Test("An illegal transition names both states")
    func illegalTransition() {
        let error = map(
            "INVALID_LIFECYCLE_TRANSITION",
            context: .init(sankalpa: sankalpa(state: .stopped), today: today, target: .paused)
        )

        #expect(error == .lifecycle(.invalidLifecycleTransition(from: .stopped, to: .paused)))
    }

    @Test("A begin before the start date names the start date")
    func transitionBeforeStart() {
        let error = map(
            "TRANSITION_BEFORE_START",
            context: .init(sankalpa: sankalpa(), today: today, target: .inProgress)
        )

        #expect(error == .lifecycle(.transitionBeforeStart(startDate: day(2026, 9, 1))))
    }

    @Test("A begin effective in the future comes back as the app's own refusal")
    func transitionInFuture() {
        #expect(
            map("TRANSITION_IN_FUTURE", context: .init(today: today))
                == .lifecycle(.transitionInFuture)
        )
    }

    // MARK: - Declaration

    /// The app bounds the start-date picker itself, so this is the service catching a clock that
    /// disagrees. The earliest allowed date is derived locally because the service does not send it.
    @Test("A start date too far in the past names the earliest allowed date")
    func startDateTooFarInPast() {
        let error = map("START_DATE_TOO_FAR_IN_PAST", context: .init(today: today))
        #expect(error == .declaration(.startDateTooFarInPast(earliestAllowed: day(2025, 9, 10))))
    }

    @Test("A blank and an over-long title are told apart by what was sent")
    func titleProblems() {
        func declaration(_ title: String) -> Declaration {
            Declaration(
                title: title, actionType: .meditation, startDate: today,
                periodUnit: .day, timesPerPeriod: 1
            )
        }

        #expect(
            map("INVALID_TITLE", context: .init(today: today, declaration: declaration("   ")))
                == .declaration(.invalidTitle(.blank))
        )
        #expect(
            map("INVALID_TITLE", context: .init(today: today, declaration: declaration("Vipassana")))
                == .declaration(.invalidTitle(.tooLong(max: Title.maxLength)))
        )
    }

    // MARK: - Everything that is not a domain rule

    @Test("An unreachable service is reported as a storage failure, with its own wording")
    func unreachableService() {
        let error = ServerRefusal.commandError(
            for: .unreachable("The Sankalpa service is not answering."),
            context: .init(today: today)
        )

        #expect(error == .storage(.unavailable("The Sankalpa service is not answering.")))
    }

    @Test("A stale copy is explained as something to refresh past")
    func concurrentModification() {
        let error = map("CONCURRENT_MODIFICATION", context: .init(today: today))
        #expect(error.message.contains("refresh"))
    }

    @Test("Reusing a command ID for different values is explained as a conflict")
    func idempotencyConflict() {
        let error = map(
            "IDEMPOTENCY_CONFLICT",
            detail: "The command ID has already been used.",
            context: .init(today: today)
        )

        #expect(error == .conflict("The command ID has already been used."))
    }

    /// A code this version has never heard of must not become a blank or a lie. The service's own
    /// sentence is the only thing that can explain a rule the app does not model.
    @Test("An unknown code falls back to the service's own explanation")
    func unknownCode() {
        let error = map(
            "SOME_FUTURE_RULE", detail: "Sankalpas may not overlap.",
            context: .init(today: today)
        )

        #expect(error.message == "Sankalpas may not overlap.")
    }

    /// Several refusals need the sankalpa to say their sentence. Without it the app must still say
    /// something true rather than crash or invent a date.
    @Test("A refusal that needs context it does not have still says something true")
    func missingContextFallsBack() {
        let error = map(
            "SESSION_AFTER_COMMITMENT_END", detail: "Session cannot occur after the end date",
            context: .init(today: today)
        )

        #expect(error.message == "Session cannot occur after the end date")
    }
}
