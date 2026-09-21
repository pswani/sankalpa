import Foundation

/// The aggregate root. It owns the commitment and the lifecycle, and it is the only thing that may
/// decide whether a session can be logged.
public struct Sankalpa: Identifiable, Codable, Sendable, Hashable {
    /// S3 — a sankalpa may start at most one year in the past.
    public static let maximumBackdatedStartInYears = 1

    public let id: SankalpaId
    public let declaredAt: CalendarMoment
    public private(set) var title: Title
    public private(set) var description: SankalpaDescription
    public private(set) var actionType: ActionType
    public private(set) var commitment: Commitment
    public private(set) var lifecycle: LifecycleTimeline

    private init(
        id: SankalpaId,
        declaredAt: CalendarMoment,
        title: Title,
        description: SankalpaDescription,
        actionType: ActionType,
        commitment: Commitment,
        lifecycle: LifecycleTimeline
    ) {
        self.id = id
        self.declaredAt = declaredAt
        self.title = title
        self.description = description
        self.actionType = actionType
        self.commitment = commitment
        self.lifecycle = lifecycle
    }

    // MARK: - Declaring

    public static func declare(
        id: SankalpaId = SankalpaId(),
        _ declaration: Declaration,
        now: CalendarMoment
    ) throws(DeclarationError) -> Sankalpa {
        let title = try Title(declaration.title)
        let timesPerPeriod = try TimesPerPeriod(declaration.timesPerPeriod)
        var periodCount: PeriodCount?
        if let declaredCount = declaration.periodCount {
            periodCount = try PeriodCount(declaredCount)
        }

        let earliestStart = now.day.addingYears(-maximumBackdatedStartInYears)
        guard declaration.startDate >= earliestStart else {
            throw .startDateTooFarInPast(earliestAllowed: earliestStart)
        }

        return Sankalpa(
            id: id,
            declaredAt: now,
            title: title,
            description: SankalpaDescription(declaration.description),
            actionType: declaration.actionType,
            commitment: Commitment(
                startDate: declaration.startDate,
                periodUnit: declaration.periodUnit,
                timesPerPeriod: timesPerPeriod,
                periodCount: periodCount
            ),
            lifecycle: LifecycleTimeline()
        )
    }

    /// Rebuilds a sankalpa from stored data without re-running declaration rules.
    public static func rehydrate(
        id: SankalpaId,
        declaredAt: CalendarMoment,
        title: Title,
        description: SankalpaDescription,
        actionType: ActionType,
        commitment: Commitment,
        lifecycle: LifecycleTimeline
    ) -> Sankalpa {
        Sankalpa(
            id: id,
            declaredAt: declaredAt,
            title: title,
            description: description,
            actionType: actionType,
            commitment: commitment,
            lifecycle: lifecycle
        )
    }

    // MARK: - Derived state

    public var state: LifecycleState { lifecycle.current }
    public var startDate: CalendarDay { commitment.startDate }
    /// S6, S15 — derived and inclusive. Reaching it changes nothing about the lifecycle.
    public var endDate: CalendarDay? { commitment.endDate }

    // MARK: - Lifecycle

    /// S11 — the only transition that may be backdated. Its effective time may be in the past, but
    /// never in the future and never before the commitment's start date.
    public mutating func begin(_ timing: BeginTiming) throws(LifecycleTransitionError) {
        try lifecycle.record(
            to: .inProgress,
            effectiveAt: timing.effectiveAt,
            recordedAt: timing.recordedAt,
            commitmentStart: commitment.startDate
        )
    }

    public mutating func pause(now: CalendarMoment) throws(LifecycleTransitionError) {
        try transitionNow(to: .paused, now: now)
    }

    public mutating func resume(now: CalendarMoment) throws(LifecycleTransitionError) {
        try transitionNow(to: .inProgress, now: now)
    }

    public mutating func complete(
        _ outcome: CompletionOutcome,
        now: CalendarMoment
    ) throws(LifecycleTransitionError) {
        try transitionNow(to: outcome.state, now: now)
    }

    public mutating func stop(now: CalendarMoment) throws(LifecycleTransitionError) {
        try transitionNow(to: .stopped, now: now)
    }

    /// S14 — Pause, Resume, Complete and Stop always take effect when the user performs them.
    private mutating func transitionNow(
        to target: LifecycleState,
        now: CalendarMoment
    ) throws(LifecycleTransitionError) {
        try lifecycle.record(
            to: target,
            effectiveAt: now,
            recordedAt: now,
            commitmentStart: commitment.startDate
        )
    }

    // MARK: - Session logging

    /// S9, S10 — a session may be logged only for a moment that has already passed, that the
    /// commitment covers, and at which the sankalpa was In progress.
    public func logSession(
        id sessionId: SessionId = SessionId(),
        occurredAt: CalendarMoment,
        now: CalendarMoment
    ) throws(SessionNotLoggable) -> Session {
        guard occurredAt <= now else { throw .sessionInFuture }
        guard occurredAt.day >= commitment.startDate else {
            throw .sessionBeforeCommitmentStart(startDate: commitment.startDate)
        }
        if let endDate = commitment.endDate, occurredAt.day > endDate {
            throw .sessionAfterCommitmentEnd(endDate: endDate)
        }
        let stateThen = lifecycle.state(at: occurredAt)
        guard stateThen == .inProgress else {
            throw .sankalpaNotInProgressAtThatTime(state: stateThen)
        }

        return Session(
            id: sessionId,
            sankalpaId: id,
            occurredAt: occurredAt,
            loggedAt: now
        )
    }

    /// Whether logging is worth offering at all right now — used to decide whether the UI shows a
    /// log affordance, not as a substitute for `logSession`'s checks.
    public func acceptsSessions(asOf now: CalendarMoment) -> Bool {
        guard commitment.startDate <= now.day else { return false }
        if let endDate = commitment.endDate, now.day > endDate, lifecycle.beganAt == nil {
            return false
        }
        return lifecycle.beganAt != nil
    }
}
