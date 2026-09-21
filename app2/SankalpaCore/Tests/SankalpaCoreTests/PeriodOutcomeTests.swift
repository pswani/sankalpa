import Testing
@testable import SankalpaCore

@Suite("Period outcomes")
struct PeriodOutcomeTests {

    /// "Go to the gym 4 times per week" — weekly windows from January 1, 2026 (a Thursday).
    private func gym(periodCount: Int? = 8) throws -> Sankalpa {
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 1, 1), unit: .week, timesPerPeriod: 4, periodCount: periodCount,
            now: moment(2026, 1, 1, 5)
        )
        try sankalpa.begin(BeginTiming(now: moment(2026, 1, 1, 6)))
        return sankalpa
    }

    private func sessions(_ sankalpa: Sankalpa, _ days: [(Int, Int, Int)]) -> [Session] {
        days.map {
            Session.rehydrate(
                id: SessionId(),
                sankalpaId: sankalpa.id,
                occurredAt: moment($0.0, $0.1, $0.2, 18),
                loggedAt: moment($0.0, $0.1, $0.2, 19)
            )
        }
    }

    private func tally(
        _ sankalpa: Sankalpa,
        _ performed: [Session],
        from: CalendarDay = day(2026, 1, 1),
        until: CalendarDay = day(2026, 3, 1),
        today: CalendarDay
    ) -> [PeriodOutcome] {
        PeriodOutcomeCalculator.tally(
            commitment: sankalpa.commitment,
            lifecycle: sankalpa.lifecycle,
            sessions: performed,
            range: from...until,
            today: today
        )
    }

    // MARK: - Satisfaction arithmetic (S12, DD-13)

    @Test("Meeting the minimum satisfies the period; exceeding it also satisfies")
    func minimumIsAFloor() throws {
        let sankalpa = try gym()
        let performed = sessions(sankalpa, [
            (2026, 1, 1), (2026, 1, 2), (2026, 1, 3), (2026, 1, 5),          // week 0: exactly 4
            (2026, 1, 8), (2026, 1, 9), (2026, 1, 10), (2026, 1, 11), (2026, 1, 12), (2026, 1, 13)  // week 1: 6
        ])
        let outcomes = tally(sankalpa, performed, today: day(2026, 1, 20))

        #expect(outcomes[0].standing == .satisfied)
        #expect(outcomes[0].performed == 4)
        #expect(outcomes[0].missed == 0)
        #expect(!outcomes[0].exceededCommitment)

        #expect(outcomes[1].standing == .satisfied)
        #expect(outcomes[1].performed == 6)
        #expect(outcomes[1].missed == 0)
        #expect(outcomes[1].exceededCommitment)
    }

    @Test("A closed period short of the minimum is missed by the shortfall")
    func shortfallIsMissed() throws {
        let sankalpa = try gym()
        let performed = sessions(sankalpa, [(2026, 1, 1), (2026, 1, 3)])
        let outcomes = tally(sankalpa, performed, today: day(2026, 1, 20))

        #expect(outcomes[0].standing == .unsatisfied)
        #expect(outcomes[0].required == 4)
        #expect(outcomes[0].performed == 2)
        #expect(outcomes[0].missed == 2)
    }

    @Test("A period with no sessions at all is missed in full")
    func emptyPeriodMissesEverything() throws {
        let sankalpa = try gym()
        let outcomes = tally(sankalpa, [], today: day(2026, 1, 20))
        #expect(outcomes[0].missed == 4)
        #expect(outcomes[1].missed == 4)
    }

    // MARK: - Open windows

    @Test("The window the user is living in is open, not missed")
    func currentWindowIsOpen() throws {
        let sankalpa = try gym()
        let performed = sessions(sankalpa, [(2026, 1, 8)])
        let outcomes = tally(sankalpa, performed, today: day(2026, 1, 10))

        #expect(outcomes[0].standing == .unsatisfied)   // week 0 closed
        #expect(outcomes[1].standing == .open)          // week 1 contains today
        #expect(outcomes[1].performed == 1)
        #expect(outcomes[1].missed == 0)
        #expect(outcomes[2].standing == .open)          // future weeks are open too
    }

    @Test("A window closes only once the day after its end has arrived")
    func windowClosesAfterItsLastDay() throws {
        let sankalpa = try gym()
        #expect(tally(sankalpa, [], today: day(2026, 1, 7))[0].standing == .open)
        #expect(tally(sankalpa, [], today: day(2026, 1, 8))[0].standing == .unsatisfied)
    }

    // MARK: - Pause (S13, DD-14)

    @Test("A fully paused period is reported as Paused with no shortfall")
    func fullyPausedPeriod() throws {
        var sankalpa = try gym()
        try sankalpa.pause(now: moment(2026, 1, 7, 20))
        try sankalpa.resume(now: moment(2026, 1, 17, 9))

        let outcomes = tally(sankalpa, [], today: day(2026, 2, 1))
        #expect(outcomes[1].standing == .paused)   // Jan 8–14, paused end to end
        #expect(outcomes[1].missed == 0)
    }

    @Test("A partly paused period keeps its full requirement and is evaluated normally")
    func partiallyPausedPeriod() throws {
        var sankalpa = try gym()
        try sankalpa.pause(now: moment(2026, 1, 9, 20))    // partway through week 1
        try sankalpa.resume(now: moment(2026, 1, 20, 9))   // partway through week 2

        let performed = sessions(sankalpa, [(2026, 1, 8), (2026, 1, 9)])
        let outcomes = tally(sankalpa, performed, today: day(2026, 2, 1))

        #expect(outcomes[1].standing == .unsatisfied)
        #expect(outcomes[1].required == 4)            // not prorated
        #expect(outcomes[1].performed == 2)
        #expect(outcomes[1].missed == 2)

        // Week 2 (Jan 15–21) contains the Jan 20 resume, so it is only partly paused and is
        // judged normally rather than being exempted.
        #expect(outcomes[2].standing == .unsatisfied)
        #expect(outcomes[2].required == 4)
        #expect(outcomes[2].missed == 4)
    }

    @Test("A brief pause does not exempt the week it falls in")
    func briefPauseDoesNotExemptTheWeek() throws {
        var sankalpa = try gym()
        try sankalpa.pause(now: moment(2026, 1, 9, 9))
        try sankalpa.resume(now: moment(2026, 1, 9, 17))

        let outcomes = tally(sankalpa, [], today: day(2026, 2, 1))
        #expect(outcomes[1].standing == .unsatisfied)
        #expect(outcomes[1].missed == 4)
    }

    @Test("Pausing does not shift period boundaries or extend the end date")
    func pauseDoesNotShiftBoundaries() throws {
        var sankalpa = try gym()
        let endBefore = sankalpa.endDate
        try sankalpa.pause(now: moment(2026, 1, 10, 9))
        try sankalpa.resume(now: moment(2026, 2, 10, 9))

        #expect(sankalpa.endDate == endBefore)
        #expect(sankalpa.commitment.window(at: 1)!.start == day(2026, 1, 8))
    }

    // MARK: - Terminal cutoff (S16, DD-16)

    @Test("Stopping omits the interrupted period and every period after it")
    func terminalCutoff() throws {
        var sankalpa = try gym(periodCount: nil)
        // Weeks: 0 = Jan 1–7, 1 = Jan 8–14, 2 = Jan 15–21.
        try sankalpa.stop(now: moment(2026, 1, 17, 9))    // partway through week 2

        let outcomes = tally(sankalpa, [], until: day(2026, 3, 1), today: day(2026, 3, 1))
        #expect(outcomes.map(\.window.index) == [0, 1])
        #expect(outcomes.allSatisfy { $0.standing == .unsatisfied })
    }

    @Test("A terminal transition on the day after a window closes still evaluates that window")
    func terminalRightAfterAWindow() throws {
        var sankalpa = try gym(periodCount: nil)
        try sankalpa.complete(.successfully, now: moment(2026, 1, 15, 0, 30))

        let outcomes = tally(sankalpa, [], until: day(2026, 3, 1), today: day(2026, 3, 1))
        #expect(outcomes.map(\.window.index) == [0, 1])   // Jan 8–14 ended before the transition
    }

    @Test("Reaching the end date evaluates every window even while still In progress")
    func endDateWithoutTerminalTransition() throws {
        let sankalpa = try gym(periodCount: 4)
        #expect(sankalpa.endDate == day(2026, 1, 28))
        #expect(sankalpa.state == .inProgress)

        let outcomes = tally(sankalpa, [], until: day(2026, 3, 1), today: day(2026, 2, 15))
        #expect(outcomes.count == 4)
        #expect(outcomes.allSatisfy { $0.standing == .unsatisfied })
    }

    // MARK: - Range bounding (DD-17)

    @Test("Only windows starting inside the requested range are evaluated")
    func rangeBounded() throws {
        let sankalpa = try gym(periodCount: nil)
        let outcomes = tally(
            sankalpa, [], from: day(2026, 1, 8), until: day(2026, 1, 22), today: day(2026, 3, 1)
        )
        #expect(outcomes.map(\.window.index) == [1, 2, 3])
    }

    @Test("A mid-window range start does not undercount, because the caller widens the session query")
    func sessionQueryIsWidened() throws {
        let sankalpa = try gym(periodCount: nil)
        let windows = sankalpa.commitment.windowsStartingBetween(day(2026, 1, 8), day(2026, 1, 14))
        let range = PeriodOutcomeCalculator.sessionRange(covering: windows)
        #expect(range?.lowerBound == day(2026, 1, 8))
        #expect(range?.upperBound == day(2026, 1, 14))
    }
}
