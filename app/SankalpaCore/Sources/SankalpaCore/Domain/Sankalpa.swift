import Foundation

/// The aggregate root. It owns the commitment and the lifecycle, and it is the only thing that may
/// decide whether a session can be logged.
public struct Sankalpa: Identifiable, Codable, Sendable, Hashable {
    /// S3 — a sankalpa may start at most one year in the past.
    public static let maximumBackdatedStartInYears = 1

    public let seriesId: SankalpaId
    public let extensionOf: SankalpaId?
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
        lifecycle: LifecycleTimeline,
        seriesId: SankalpaId? = nil,
        extensionOf: SankalpaId? = nil
    ) {
        self.seriesId = seriesId ?? id
        self.extensionOf = extensionOf
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
        lifecycle: LifecycleTimeline,
        seriesId: SankalpaId? = nil,
        extensionOf: SankalpaId? = nil
    ) -> Sankalpa {
        Sankalpa(
            id: id,
            declaredAt: declaredAt,
            title: title,
            description: description,
            actionType: actionType,
            commitment: commitment,
            lifecycle: lifecycle, seriesId: seriesId, extensionOf: extensionOf
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, declaredAt, title, description, actionType, commitment, lifecycle, seriesId, extensionOf
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(SankalpaId.self, forKey: .id)
        seriesId = try values.decodeIfPresent(SankalpaId.self, forKey: .seriesId) ?? id
        extensionOf = try values.decodeIfPresent(SankalpaId.self, forKey: .extensionOf)
        declaredAt = try values.decode(CalendarMoment.self, forKey: .declaredAt)
        title = try values.decode(Title.self, forKey: .title)
        description = try values.decode(SankalpaDescription.self, forKey: .description)
        actionType = try values.decode(ActionType.self, forKey: .actionType)
        commitment = try values.decode(Commitment.self, forKey: .commitment)
        let ownerId = id
        let old = try values.decode(LifecycleTimeline.self, forKey: .lifecycle)
        lifecycle = LifecycleTimeline(current: old.current, transitions: old.transitions.map {
            LifecycleTransition(from: $0.from, to: $0.to, effectiveAt: $0.effectiveAt,
                                recordedAt: $0.recordedAt, originSankalpaId: $0.originSankalpaId ?? ownerId)
        })
    }

    public func acceptsPerformedAt(_ at: CalendarMoment) -> Bool {
        at.day >= startDate && (endDate == nil || at.day <= endDate!) && lifecycle.wasInProgress(at: at)
    }

    public var canExtend: Bool {
        commitment.periodCount != nil && (state == .inProgress || state == .paused)
    }

    /// A total duration from the original start, with a value copy of the source's timeline.
    public func extended(id: SankalpaId = SankalpaId(), totalPeriodCount: Int,
                         now: CalendarMoment) throws -> Sankalpa {
        guard canExtend else { throw ExtensionError.sourceNotExtendable }
        guard id != self.id else { throw ExtensionError.invalidIdentity }
        let count = try PeriodCount(totalPeriodCount)
        guard count.value > commitment.periodCount!.value else { throw ExtensionError.durationNotGreater }
        guard now >= declaredAt, lifecycle.transitions.allSatisfy({ $0.recordedAt <= now }) else {
            throw ExtensionError.clockMovedBackwards
        }
        let longer = Commitment(startDate: startDate, periodUnit: commitment.periodUnit,
                                timesPerPeriod: commitment.timesPerPeriod, periodCount: count)
        guard longer.endDate! >= now.day else { throw ExtensionError.endsInPast }
        return Sankalpa(id: id, declaredAt: now, title: title, description: description,
                        actionType: actionType, commitment: longer, lifecycle: lifecycle,
                        seriesId: seriesId, extensionOf: self.id)
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
        // Begin is specifically the first transition. Without this, `begin` on a Paused sankalpa
        // would be accepted as a resume — and, because Begin may be backdated, would rewrite the
        // end of the paused interval into the past.
        guard state == .notStarted else {
            throw .invalidLifecycleTransition(from: state, to: .inProgress)
        }
        try lifecycle.record(
            to: .inProgress,
            effectiveAt: timing.effectiveAt,
            recordedAt: timing.recordedAt,
            commitmentStart: commitment.startDate, originSankalpaId: id
        )
    }

    public mutating func pause(now: CalendarMoment) throws(LifecycleTransitionError) {
        try transitionNow(to: .paused, now: now)
    }

    public mutating func resume(now: CalendarMoment) throws(LifecycleTransitionError) {
        guard state == .paused else {
            throw .invalidLifecycleTransition(from: state, to: .inProgress)
        }
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
            commitmentStart: commitment.startDate, originSankalpaId: id
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
}
