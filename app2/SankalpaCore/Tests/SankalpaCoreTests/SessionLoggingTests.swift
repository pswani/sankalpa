import Testing
@testable import SankalpaCore

@Suite("Session logging")
struct SessionLoggingTests {

    /// Thirty daily sessions beginning January 1, already In progress from the start.
    private func inProgress(
        unit: PeriodUnit = .day,
        timesPerPeriod: Int = 1,
        periodCount: Int? = 30,
        beganAt: CalendarMoment = moment(2026, 1, 1, 6)
    ) throws -> Sankalpa {
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 1, 1),
            unit: unit,
            timesPerPeriod: timesPerPeriod,
            periodCount: periodCount,
            now: moment(2026, 1, 1, 5)
        )
        try sankalpa.begin(BeginTiming(effectiveAt: beganAt, recordedAt: beganAt))
        return sankalpa
    }

    // MARK: - S9

    @Test("A session in the future is refused")
    func futureSessionRefused() throws {
        let sankalpa = try inProgress()
        #expect(throws: SessionNotLoggable.sessionInFuture) {
            try sankalpa.logSession(occurredAt: moment(2026, 1, 10, 9), now: moment(2026, 1, 5, 9))
        }
    }

    @Test("A session at exactly the current moment is accepted")
    func sessionAtNowAccepted() throws {
        let sankalpa = try inProgress()
        let now = moment(2026, 1, 5, 9)
        let session = try sankalpa.logSession(occurredAt: now, now: now)
        #expect(session.occurredAt == now)
        #expect(session.loggedAt == now)
        #expect(session.sankalpaId == sankalpa.id)
    }

    // MARK: - S10 — commitment coverage

    @Test("Nothing can be logged before the start date")
    func beforeStartRefused() throws {
        let sankalpa = try inProgress()
        #expect(throws: SessionNotLoggable.sessionBeforeCommitmentStart(startDate: day(2026, 1, 1))) {
            try sankalpa.logSession(occurredAt: moment(2025, 12, 31, 9), now: moment(2026, 1, 5, 9))
        }
    }

    @Test("Nothing can be logged after the end date")
    func afterEndRefused() throws {
        let sankalpa = try inProgress()
        #expect(sankalpa.endDate == day(2026, 1, 30))
        #expect(throws: SessionNotLoggable.sessionAfterCommitmentEnd(endDate: day(2026, 1, 30))) {
            try sankalpa.logSession(occurredAt: moment(2026, 1, 31, 9), now: moment(2026, 2, 5, 9))
        }
        // The end date itself is still covered.
        let onEndDate = try sankalpa.logSession(
            occurredAt: moment(2026, 1, 30, 23), now: moment(2026, 2, 5, 9)
        )
        #expect(onEndDate.occurredAt.day == day(2026, 1, 30))
    }

    @Test("An indefinite sankalpa accepts sessions with no end boundary")
    func indefiniteHasNoEnd() throws {
        let sankalpa = try inProgress(unit: .week, timesPerPeriod: 4, periodCount: nil)
        #expect(sankalpa.endDate == nil)
        let session = try sankalpa.logSession(
            occurredAt: moment(2028, 6, 1, 9), now: moment(2028, 6, 1, 10)
        )
        #expect(session.occurredAt.day == day(2028, 6, 1))
    }

    // MARK: - S10 — lifecycle at the time of the session

    @Test("A session is refused for a time when the sankalpa had not begun")
    func beforeBeginRefused() throws {
        let sankalpa = try inProgress(beganAt: moment(2026, 1, 10, 6))
        #expect(throws: SessionNotLoggable.sankalpaNotInProgressAtThatTime(state: .notStarted)) {
            try sankalpa.logSession(occurredAt: moment(2026, 1, 5, 9), now: moment(2026, 1, 15, 9))
        }
    }

    @Test("A session is refused for a time inside a paused interval")
    func pausedIntervalRefused() throws {
        var sankalpa = try inProgress()
        try sankalpa.pause(now: moment(2026, 1, 5, 9))
        try sankalpa.resume(now: moment(2026, 1, 9, 9))

        #expect(throws: SessionNotLoggable.sankalpaNotInProgressAtThatTime(state: .paused)) {
            try sankalpa.logSession(occurredAt: moment(2026, 1, 7, 9), now: moment(2026, 1, 12, 9))
        }
        // Either side of the pause is fine.
        _ = try sankalpa.logSession(occurredAt: moment(2026, 1, 3, 9), now: moment(2026, 1, 12, 9))
        _ = try sankalpa.logSession(occurredAt: moment(2026, 1, 10, 9), now: moment(2026, 1, 12, 9))
    }

    @Test("After stopping, a past session from the In progress period can still be backfilled")
    func backfillAfterStop() throws {
        var sankalpa = try inProgress()
        try sankalpa.stop(now: moment(2026, 1, 20, 9))

        let session = try sankalpa.logSession(
            occurredAt: moment(2026, 1, 12, 7), now: moment(2026, 1, 21, 9)
        )
        #expect(session.occurredAt.day == day(2026, 1, 12))
        #expect(session.wasBackdated)

        // But not for a time after the sankalpa was stopped.
        #expect(throws: SessionNotLoggable.sankalpaNotInProgressAtThatTime(state: .stopped)) {
            try sankalpa.logSession(occurredAt: moment(2026, 1, 21, 7), now: moment(2026, 1, 21, 9))
        }
    }
}
