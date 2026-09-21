import Testing
@testable import SankalpaCore

/// One test per defect found in review, kept apart from the behavioural suites so it stays obvious
/// which rules exist because something was once wrong.
@Suite("Review regressions")
struct ReviewRegressionTests {

    @Test("A sankalpa that has not started yet can still be stopped")
    func futureSankalpaCanStopBeforeItStarts() throws {
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 9, 22), unit: .day, timesPerPeriod: 1,
            now: moment(2026, 9, 21, 9)
        )
        try sankalpa.stop(now: moment(2026, 9, 21, 9))

        #expect(sankalpa.state == .stopped)
        // Nothing ran, so nothing is judged.
        #expect(
            PeriodOutcomeCalculator.tally(
                commitment: sankalpa.commitment,
                lifecycle: sankalpa.lifecycle,
                sessions: [],
                range: day(2026, 9, 21)...day(2026, 9, 30),
                today: day(2026, 10, 1)
            ).isEmpty
        )
    }

    @Test("Begin cannot be used to backdate a resume")
    func beginCannotBackdateAResume() throws {
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 9, 21), unit: .day, timesPerPeriod: 1,
            now: moment(2026, 9, 21, 7)
        )
        try sankalpa.begin(BeginTiming(now: moment(2026, 9, 21, 7)))
        try sankalpa.pause(now: moment(2026, 9, 21, 8))

        #expect(throws: LifecycleTransitionError.invalidLifecycleTransition(from: .paused, to: .inProgress)) {
            try sankalpa.begin(
                BeginTiming(effectiveAt: moment(2026, 9, 21, 9), recordedAt: moment(2026, 9, 21, 12))
            )
        }
        // The paused interval is intact.
        #expect(sankalpa.state == .paused)
        #expect(sankalpa.lifecycle.transitions.count == 2)
    }

    @Test("Resume cannot stand in for the first Begin")
    func resumeCannotReplaceTheInitialBegin() {
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 9, 21), unit: .day, timesPerPeriod: 1,
            now: moment(2026, 9, 21, 7)
        )
        #expect(throws: LifecycleTransitionError.invalidLifecycleTransition(from: .notStarted, to: .inProgress)) {
            try sankalpa.resume(now: moment(2026, 9, 21, 8))
        }
    }

    @Test("Beginning earlier the same day makes a morning session loggable")
    func sameDayBeginAllowsAMorningSession() throws {
        // Declared at noon with today's start date; the 07:00 session already happened.
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 9, 21), unit: .day, timesPerPeriod: 1,
            now: moment(2026, 9, 21, 12)
        )
        try sankalpa.begin(
            BeginTiming(effectiveAt: moment(2026, 9, 21, 6), recordedAt: moment(2026, 9, 21, 12))
        )

        let session = try sankalpa.logSession(
            occurredAt: moment(2026, 9, 21, 7), now: moment(2026, 9, 21, 12)
        )
        #expect(session.occurredAt == moment(2026, 9, 21, 7))
    }

    @Test("The newest eligible moment stops at a pause, and at midnight belongs to the day before")
    func latestEligibleMomentRespectsPauses() throws {
        let environment = TestEnvironment(today: moment(2026, 9, 25, 9))
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 9, 21),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        try environment.service.beginSankalpa(sankalpa.id, effectiveAt: moment(2026, 9, 21, 6))

        // Paused at 10:00 on the 22nd — the last eligible instant is one second earlier.
        environment.clock.current = moment(2026, 9, 22, 10)
        try environment.service.pauseSankalpa(sankalpa.id)
        environment.clock.current = moment(2026, 9, 25, 9)

        let paused = try #require(environment.service.findSankalpa(sankalpa.id))
        #expect(
            environment.service.latestEligibleMoment(for: paused, now: environment.service.now())
                == CalendarMoment(day: day(2026, 9, 22), hour: 9, minute: 59, second: 59)
        )

        // A sankalpa that never began has no eligible moment at all.
        let unstarted = try environment.service.declareSankalpa(
            Declaration(title: "Later", actionType: .observance, startDate: day(2026, 9, 25),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        #expect(
            environment.service.latestEligibleMoment(for: unstarted, now: environment.service.now())
                == nil
        )
    }

    @Test("A command that cannot be saved fails instead of reporting success")
    func failedWriteIsReported() throws {
        let environment = TestEnvironment(today: moment(2026, 9, 21, 9))
        environment.sankalpas.failWrites = true

        #expect(throws: SankalpaCommandError.storage(.writeFailed)) {
            try environment.service.declareSankalpa(
                Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 9, 21),
                            periodUnit: .day, timesPerPeriod: 1)
            )
        }

        // A logged session must not be reported as recorded either.
        environment.sankalpas.failWrites = false
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 9, 21),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        try environment.service.beginSankalpa(sankalpa.id, effectiveAt: moment(2026, 9, 21, 6))
        environment.sessions.failWrites = true

        #expect(throws: SankalpaCommandError.storage(.writeFailed)) {
            try environment.service.logSession(sankalpa.id, occurredAt: moment(2026, 9, 21, 7))
        }
        #expect(environment.service.totalSessionCount(sankalpa.id) == 0)
    }

    @Test("The period list and the count above it cover the same range")
    func tallyAgreesWithTheListItSitsAbove() throws {
        let environment = TestEnvironment(today: moment(2026, 9, 21, 9))
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 9, 21),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        try environment.service.beginSankalpa(sankalpa.id)

        // Eleven years on — past the reported range, which is where a list and a count computed
        // over different limits would start disagreeing.
        environment.clock.advance(toDay: day(2037, 9, 21))

        let limit = SankalpaApplicationService.historyPeriodLimit
        let listed = environment.service.recentPeriodOutcomes(sankalpa.id, limit: limit)
        let tally = environment.service.periodTally(sankalpa.id)

        #expect(listed.count == limit)
        #expect(tally.satisfied + tally.unsatisfied + tally.paused == listed.count { $0.standing != .open })
        #expect(environment.service.hasPeriodsBeyond(sankalpa.id, limit: limit))
    }

    @Test("A history that fits inside the reported range is not described as cut short")
    func shortHistoryIsNotReportedAsTruncated() throws {
        let environment = TestEnvironment(today: moment(2026, 9, 21, 9))
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 9, 1),
                        periodUnit: .day, timesPerPeriod: 1, periodCount: 180)
        )
        try environment.service.beginSankalpa(sankalpa.id)

        #expect(
            !environment.service.hasPeriodsBeyond(
                sankalpa.id, limit: SankalpaApplicationService.historyPeriodLimit
            )
        )
    }

    @Test("An inverted period-outcome range returns nothing instead of trapping")
    func invertedRangeIsRefused() throws {
        let environment = TestEnvironment(today: moment(2026, 9, 21, 9))
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 9, 1),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        #expect(
            environment.service.periodOutcomes(
                sankalpa.id, from: day(2026, 9, 30), until: day(2026, 9, 1)
            ).isEmpty
        )
    }
}
