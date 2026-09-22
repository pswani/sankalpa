import Testing
@testable import SankalpaCore

/// The reads the screens are built out of.
///
/// The outcome and lifecycle rules have their own suites; these are the smaller queries that sit
/// between them and the UI, where a wrong answer is not a wrong rule but a wrong screen — a
/// lifetime count that disagrees with the list under it, a progress ring for a period the
/// sankalpa is not in, a journal that names a sankalpa that is gone.
@Suite("Query surface")
struct QuerySurfaceTests {

    /// The detail screen shows a lifetime count above a list that covers the last 120 days. The
    /// count is deliberately not the length of that list, and the two must not be confused.
    @Test("The lifetime session count is not bounded by the reported day range")
    func totalCountSpansAllHistory() throws {
        let environment = TestEnvironment(today: moment(2026, 6, 1))
        let start = day(2025, 7, 1)
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(
                title: "Vipassana",
                actionType: .meditation,
                startDate: start,
                periodUnit: .day,
                timesPerPeriod: 1
            )
        )
        try environment.service.beginSankalpa(
            sankalpa.id, effectiveAt: .startOfDay(start)
        )

        // One a month for eleven months: well outside the 120-day window the detail card
        // previews, and still inside the year a start date may be backdated by.
        var logged = 0
        for offset in stride(from: 0, through: 330, by: 30) {
            try environment.service.logSession(
                sankalpa.id, occurredAt: moment2(start.addingDays(offset))
            )
            logged += 1
        }

        #expect(environment.service.totalSessionCount(sankalpa.id) == logged)
        let recent = environment.service.sessions(
            sankalpa.id, from: day(2026, 6, 1).addingDays(-120), until: day(2026, 6, 1)
        )
        #expect(recent.count < logged, "the 120-day preview should not contain the whole history")
    }

    /// Reaching the end date does not end the lifecycle (S15). The sankalpa stays In progress
    /// with no period to be in, and the progress ring has to be absent rather than showing the
    /// last period over again.
    @Test("A day past the end date has no current period, even while still In progress")
    func noCurrentPeriodOutsideCoverage() throws {
        let environment = TestEnvironment(today: moment(2026, 1, 1))
        let start = day(2026, 1, 1)
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(
                title: "Ten days",
                actionType: .meditation,
                startDate: start,
                periodUnit: .day,
                timesPerPeriod: 1,
                periodCount: 10
            )
        )
        try environment.service.beginSankalpa(sankalpa.id, effectiveAt: .startOfDay(start))

        #expect(environment.service.currentPeriodProgress(for: reload(environment, sankalpa.id)) != nil)

        // The last covered day is the 10th; the 11th is past it.
        environment.clock.advance(toDay: start.addingDays(10))
        let afterTheEnd = reload(environment, sankalpa.id)
        #expect(afterTheEnd.lifecycle.current == .inProgress)
        #expect(environment.service.currentPeriodProgress(for: afterTheEnd) == nil)
    }

    /// A start date still to come is allowed, so today can fall *before* coverage as well as
    /// after it. Both are "no current period", and the earlier one is the easier to get wrong.
    @Test("A sankalpa waiting for a future start date has no current period either")
    func noCurrentPeriodBeforeCoverage() throws {
        let environment = TestEnvironment(today: moment(2026, 1, 1))
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(
                title: "Starts next week",
                actionType: .meditation,
                startDate: day(2026, 1, 8),
                periodUnit: .day,
                timesPerPeriod: 1,
                periodCount: 30
            )
        )
        #expect(environment.service.currentPeriodProgress(for: sankalpa) == nil)
    }

    /// An inverted range is a caller mistake, not a reason to trap or to return everything.
    @Test("An inverted day range returns nothing rather than trapping")
    func invertedRangesAreEmpty() throws {
        let environment = TestEnvironment(today: moment(2026, 3, 1))
        let start = day(2026, 2, 1)
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(
                title: "Vipassana",
                actionType: .meditation,
                startDate: start,
                periodUnit: .day,
                timesPerPeriod: 1
            )
        )
        try environment.service.beginSankalpa(sankalpa.id, effectiveAt: .startOfDay(start))
        try environment.service.logSession(sankalpa.id, occurredAt: moment2(day(2026, 2, 10)))

        #expect(environment.service.sessions(
            sankalpa.id, from: day(2026, 3, 1), until: day(2026, 2, 1)
        ).isEmpty)
        #expect(environment.service.journal(
            from: day(2026, 3, 1), until: day(2026, 2, 1)
        ).isEmpty)
        // The same range the right way round does find it, so the emptiness above is the range
        // and not a missing session.
        #expect(environment.service.journal(
            from: day(2026, 2, 1), until: day(2026, 3, 1)
        ).count == 1)
    }

    /// The journal carries each session's title and action type so the list can render without
    /// looking anything up, and they have to be the owning sankalpa's, not the first one found.
    @Test("Each journal entry carries its own sankalpa's title and action type")
    func journalEntriesAreAttributedCorrectly() throws {
        let environment = TestEnvironment(today: moment(2026, 3, 10))
        let start = day(2026, 3, 1)

        let meditation = try declareAndBegin(
            environment, title: "Vipassana", type: .meditation, start: start
        )
        let gym = try declareAndBegin(
            environment, title: "Gym", type: .physicalActivity, start: start
        )

        try environment.service.logSession(meditation, occurredAt: moment(2026, 3, 5, 6))
        try environment.service.logSession(gym, occurredAt: moment(2026, 3, 5, 18))

        let entries = environment.service.journal(from: start, until: day(2026, 3, 10))
        #expect(entries.count == 2)
        // Newest first: the gym session was later in the same day.
        #expect(entries.first?.sankalpaTitle == "Gym")
        #expect(entries.first?.actionType == .physicalActivity)
        #expect(entries.last?.sankalpaTitle == "Vipassana")
        #expect(entries.last?.actionType == .meditation)
    }

    /// The lifecycle audit trail reads newest first on screen, while the domain keeps it in the
    /// order it happened. The reversal belongs to the query, and is easy to lose.
    @Test("The lifecycle history is returned newest first")
    func lifecycleHistoryIsNewestFirst() throws {
        let environment = TestEnvironment(today: moment(2026, 3, 1))
        let start = day(2026, 3, 1)
        let id = try declareAndBegin(environment, title: "Vipassana", type: .meditation, start: start)

        environment.clock.advance(toDay: day(2026, 3, 5))
        try environment.service.pauseSankalpa(id)
        environment.clock.advance(toDay: day(2026, 3, 8))
        try environment.service.resumeSankalpa(id)

        let history = environment.service.lifecycleHistory(id)
        #expect(history.map(\.to) == [.inProgress, .paused, .inProgress])
        #expect(history.first!.recordedAt >= history.last!.recordedAt)
    }

    /// A missing sankalpa is a screen that has been left open while its subject went away, not a
    /// programming error. Every read has to answer rather than trap.
    @Test("Reads about a sankalpa that is not there answer instead of trapping")
    func readsAboutAMissingSankalpaAreEmpty() {
        let environment = TestEnvironment(today: moment(2026, 3, 10))
        let absent = SankalpaId()

        #expect(environment.service.summary(absent) == nil)
        #expect(environment.service.lifecycleHistory(absent).isEmpty)
        #expect(environment.service.totalSessionCount(absent) == 0)
        #expect(environment.service.recentPeriodOutcomes(absent).isEmpty)
        #expect(environment.service.sessions(
            absent, from: day(2026, 1, 1), until: day(2026, 3, 10)
        ).isEmpty)
        #expect(environment.service.periodTally(absent).satisfied == 0)
    }

    // MARK: - Helpers

    private func declareAndBegin(
        _ environment: TestEnvironment,
        title: String,
        type: ActionType,
        start: CalendarDay
    ) throws -> SankalpaId {
        let sankalpa = try environment.service.declareSankalpa(
            Declaration(
                title: title,
                actionType: type,
                startDate: start,
                periodUnit: .day,
                timesPerPeriod: 1
            )
        )
        try environment.service.beginSankalpa(sankalpa.id, effectiveAt: .startOfDay(start))
        return sankalpa.id
    }

    private func reload(_ environment: TestEnvironment, _ id: SankalpaId) -> Sankalpa {
        environment.sankalpas.find(id)!
    }
}

/// Midday on a given day — late enough to be in the past whenever the clock is set to 9am or
/// later on a later day, and early enough not to run into the end of the day.
private func moment2(_ value: CalendarDay) -> CalendarMoment {
    CalendarMoment(day: value, hour: 12, minute: 0)
}
