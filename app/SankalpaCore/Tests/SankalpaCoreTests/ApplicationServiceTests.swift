import Testing
@testable import SankalpaCore

@Suite("Application service")
struct ApplicationServiceTests {

    private func environment(today: CalendarMoment = moment(2026, 6, 1, 9)) -> TestEnvironment {
        TestEnvironment(today: today)
    }

    // MARK: - Declaration rules (S1, S3, S4, S5)

    @Test("A blank title is refused")
    func blankTitle() {
        let env = environment()
        #expect(throws: SankalpaCommandError.declaration(.invalidTitle(.blank))) {
            try env.service.declareSankalpa(
                Declaration(title: "   ", actionType: .meditation, startDate: day(2026, 6, 1),
                            periodUnit: .day, timesPerPeriod: 2)
            )
        }
    }

    @Test("A start date more than a year in the past is refused, exactly a year is allowed")
    func startDateWindow() throws {
        let env = environment()
        let earliest = day(2025, 6, 1)

        #expect(throws: SankalpaCommandError.declaration(.startDateTooFarInPast(earliestAllowed: earliest))) {
            try env.service.declareSankalpa(
                Declaration(title: "Too old", actionType: .meditation, startDate: day(2025, 5, 31),
                            periodUnit: .day, timesPerPeriod: 1)
            )
        }

        let accepted = try env.service.declareSankalpa(
            Declaration(title: "Exactly a year", actionType: .meditation, startDate: earliest,
                        periodUnit: .day, timesPerPeriod: 1)
        )
        #expect(accepted.startDate == earliest)
    }

    @Test("A future start date is allowed and the sankalpa waits in Not started")
    func futureStartDate() throws {
        let env = environment()
        let sankalpa = try env.service.declareSankalpa(
            Declaration(title: "Starts later", actionType: .observance, startDate: day(2026, 9, 1),
                        periodUnit: .week, timesPerPeriod: 1, periodCount: 4)
        )
        #expect(sankalpa.state == .notStarted)
        #expect(env.service.currentPeriodProgress(for: sankalpa) == nil)
    }

    @Test("Zero times per period and a zero-period duration are refused")
    func invalidQuantities() {
        let env = environment()
        #expect(throws: SankalpaCommandError.declaration(.invalidTimesPerPeriod(0))) {
            try env.service.declareSankalpa(
                Declaration(title: "Zero", actionType: .meditation, startDate: day(2026, 6, 1),
                            periodUnit: .day, timesPerPeriod: 0)
            )
        }
        #expect(throws: SankalpaCommandError.declaration(.invalidPeriodCount(0))) {
            try env.service.declareSankalpa(
                Declaration(title: "Zero periods", actionType: .meditation, startDate: day(2026, 6, 1),
                            periodUnit: .day, timesPerPeriod: 1, periodCount: 0)
            )
        }
    }

    @Test("A missing sankalpa is reported, not crashed on")
    func missingSankalpa() {
        let env = environment()
        let ghost = SankalpaId()
        #expect(throws: SankalpaCommandError.sankalpaNotFound(ghost)) {
            try env.service.pauseSankalpa(ghost)
        }
    }

    // MARK: - End-to-end use case flow

    @Test("Vipassana twice a day: declare, backdate the begin, log the backlog, see the tally")
    func vipassanaJourney() throws {
        // Declared on 20 January for a commitment that started on 1 January.
        let env = environment(today: moment(2026, 1, 20, 9))
        let sankalpa = try env.service.declareSankalpa(
            Declaration(
                title: "Vipassana", description: "Twice daily, morning and evening",
                actionType: .meditation, startDate: day(2026, 1, 1),
                periodUnit: .day, timesPerPeriod: 2, periodCount: 180
            )
        )
        #expect(sankalpa.endDate == day(2026, 6, 29))

        try env.service.beginSankalpa(sankalpa.id, effectiveAt: moment(2026, 1, 1, 6))

        // Backfill: both sessions on 1 and 2 January, only one on 3 January.
        for (dayOfMonth, hours) in [(1, [6, 18]), (2, [6, 18]), (3, [6])] {
            for hour in hours {
                try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, dayOfMonth, hour))
            }
        }

        let outcomes = env.service.periodOutcomes(sankalpa.id, from: day(2026, 1, 1), until: day(2026, 1, 5))
        #expect(outcomes.map(\.standing) == [.satisfied, .satisfied, .unsatisfied, .unsatisfied, .unsatisfied])
        #expect(outcomes[2].missed == 1)
        #expect(env.service.totalSessionCount(sankalpa.id) == 5)

        let tally = PeriodTally(outcomes: outcomes)
        #expect(tally.satisfied == 2)
        #expect(tally.unsatisfied == 3)
    }

    @Test("Gym 4 times a week with no duration runs until it is stopped")
    func gymJourney() throws {
        // Declared on 7 January for a commitment that started on the 1st.
        let env = environment(today: moment(2026, 1, 7, 20))
        let sankalpa = try env.service.declareSankalpa(
            Declaration(title: "Gym", actionType: .physicalActivity, startDate: day(2026, 1, 1),
                        periodUnit: .week, timesPerPeriod: 4)
        )
        #expect(sankalpa.endDate == nil)
        try env.service.beginSankalpa(sankalpa.id, effectiveAt: moment(2026, 1, 1, 6))

        // Week 0: three sessions, so short by one.
        for dayOfMonth in [1, 2, 4] {
            try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, dayOfMonth, 18))
        }

        env.clock.advance(toDay: day(2026, 1, 9))
        let summary = try #require(env.service.summary(sankalpa.id))
        let current = try #require(summary.currentPeriod)
        #expect(current.window.start == day(2026, 1, 8))
        #expect(current.performed == 0)
        #expect(current.remaining == 4)
        #expect(current.progressPhrase == "0 of 4 this week")
        #expect(!current.exceededCommitment)

        let recent = env.service.recentPeriodOutcomes(sankalpa.id, limit: 4)
        #expect(recent.first?.standing == .unsatisfied)
        #expect(recent.first?.missed == 1)

        try env.service.stopSankalpa(sankalpa.id)
        #expect(env.service.summary(sankalpa.id)?.state == .stopped)
    }

    @Test("A paused sankalpa refuses new sessions for the paused stretch but keeps its history")
    func pauseJourney() throws {
        let env = environment(today: moment(2026, 1, 1, 20))
        let sankalpa = try env.service.declareSankalpa(
            Declaration(title: "Sudarshan Kriya", actionType: .pranayama, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 1, periodCount: 60)
        )
        try env.service.beginSankalpa(sankalpa.id, effectiveAt: moment(2026, 1, 1, 6))
        try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, 1, 7))

        env.clock.advance(toDay: day(2026, 1, 2))
        try env.service.pauseSankalpa(sankalpa.id)

        env.clock.advance(toDay: day(2026, 1, 4))
        #expect(throws: SankalpaCommandError.session(.sankalpaNotInProgressAtThatTime(state: .paused))) {
            try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, 3, 7))
        }

        try env.service.resumeSankalpa(sankalpa.id)          // effective 4 January, 09:00
        env.clock.current = moment(2026, 1, 4, 18)
        try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, 4, 14))
        #expect(env.service.totalSessionCount(sankalpa.id) == 2)

        let history = env.service.lifecycleHistory(sankalpa.id)
        #expect(history.map(\.to) == [.inProgress, .paused, .inProgress])   // newest first
    }

    // MARK: - Queries

    @Test("The journal gathers sessions from every sankalpa, newest first")
    func journalAcrossSankalpas() throws {
        let env = environment(today: moment(2026, 1, 10, 20))
        let meditation = try env.service.declareSankalpa(
            Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        let gym = try env.service.declareSankalpa(
            Declaration(title: "Gym", actionType: .physicalActivity, startDate: day(2026, 1, 1),
                        periodUnit: .week, timesPerPeriod: 3)
        )
        try env.service.beginSankalpa(meditation.id, effectiveAt: moment(2026, 1, 1, 6))
        try env.service.beginSankalpa(gym.id, effectiveAt: moment(2026, 1, 1, 6))

        try env.service.logSession(meditation.id, occurredAt: moment(2026, 1, 8, 7))
        try env.service.logSession(gym.id, occurredAt: moment(2026, 1, 9, 18))
        try env.service.logSession(meditation.id, occurredAt: moment(2026, 1, 10, 7))

        let entries = env.service.journal(from: day(2026, 1, 1), until: day(2026, 1, 10))
        #expect(entries.map(\.sankalpaTitle) == ["Sahaj", "Gym", "Sahaj"])
        #expect(entries.first?.occurredAt.day == day(2026, 1, 10))
    }

    @Test("The list puts sankalpas needing attention first and terminal ones last")
    func listOrdering() throws {
        let env = environment(today: moment(2026, 1, 5, 9))
        let needsWork = try env.service.declareSankalpa(
            Declaration(title: "Needs work", actionType: .meditation, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        let done = try env.service.declareSankalpa(
            Declaration(title: "Done today", actionType: .pranayama, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        let stopped = try env.service.declareSankalpa(
            Declaration(title: "Stopped", actionType: .observance, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        for id in [needsWork.id, done.id, stopped.id] {
            try env.service.beginSankalpa(id, effectiveAt: moment(2026, 1, 1, 6))
        }
        try env.service.logSession(done.id, occurredAt: moment(2026, 1, 5, 7))
        try env.service.stopSankalpa(stopped.id)

        #expect(env.service.summaries().map(\.title) == ["Needs work", "Done today", "Stopped"])
        #expect(env.service.activeSummaries().map(\.title) == ["Needs work", "Done today"])
    }

    @Test("Undoing a just-logged session removes it and restores the period")
    func undoLoggedSession() throws {
        let env = environment(today: moment(2026, 1, 1, 20))
        let sankalpa = try env.service.declareSankalpa(
            Declaration(title: "Sahaj", actionType: .meditation, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 2)
        )
        try env.service.beginSankalpa(sankalpa.id, effectiveAt: moment(2026, 1, 1, 6))

        let first = try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, 1, 7))
        let second = try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, 1, 19))
        #expect(env.service.currentPeriodProgress(for: sankalpa)?.isSatisfied == true)

        env.service.undoLoggedSession(second.id)

        let current = try #require(env.service.currentPeriodProgress(for: sankalpa))
        #expect(current.performed == 1)
        #expect(!current.isSatisfied)
        #expect(env.service.totalSessionCount(sankalpa.id) == 1)
        // The earlier session is untouched — undo removes exactly what it was given.
        #expect(env.service.sessions(sankalpa.id, from: day(2026, 1, 1), until: day(2026, 1, 1))
            .map(\.id) == [first.id])
    }

    @Test("Passing the minimum is worded as a surplus, not as 3 of 2")
    func exceedingTheCommitmentIsWordedPlainly() throws {
        let env = environment(today: moment(2026, 1, 1, 20))
        let sankalpa = try env.service.declareSankalpa(
            Declaration(title: "Vipassana", actionType: .meditation, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 2)
        )
        try env.service.beginSankalpa(sankalpa.id, effectiveAt: moment(2026, 1, 1, 6))
        for hour in [7, 13, 19] {
            try env.service.logSession(sankalpa.id, occurredAt: moment(2026, 1, 1, hour))
        }

        let current = try #require(env.service.currentPeriodProgress(for: sankalpa))
        #expect(current.performed == 3)
        #expect(current.isSatisfied)
        #expect(current.exceededCommitment)
        #expect(current.remaining == 0)
        #expect(current.progressPhrase == "3 today · 2 committed")
        #expect(current.sessionCountPhrase == "3 sessions · 2 committed")
    }

    @Test("A sankalpa waiting to begin is ordered below the ones needing action today")
    func waitingToBeginOrdering() throws {
        let env = environment(today: moment(2026, 1, 5, 9))
        let needsWork = try env.service.declareSankalpa(
            Declaration(title: "Needs work", actionType: .meditation, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        try env.service.beginSankalpa(needsWork.id, effectiveAt: moment(2026, 1, 1, 6))

        let paused = try env.service.declareSankalpa(
            Declaration(title: "Paused", actionType: .pranayama, startDate: day(2026, 1, 1),
                        periodUnit: .day, timesPerPeriod: 1)
        )
        try env.service.beginSankalpa(paused.id, effectiveAt: moment(2026, 1, 1, 6))
        try env.service.pauseSankalpa(paused.id)

        // Declared with start dates still to come; the sooner one should come first.
        try env.service.declareSankalpa(
            Declaration(title: "Starts later", actionType: .observance, startDate: day(2026, 3, 1),
                        periodUnit: .week, timesPerPeriod: 1)
        )
        try env.service.declareSankalpa(
            Declaration(title: "Starts soon", actionType: .observance, startDate: day(2026, 1, 9),
                        periodUnit: .week, timesPerPeriod: 1)
        )

        #expect(
            env.service.summaries().map(\.title)
                == ["Needs work", "Paused", "Starts soon", "Starts later"]
        )
    }
}
