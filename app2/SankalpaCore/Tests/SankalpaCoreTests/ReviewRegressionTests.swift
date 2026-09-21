import Testing
@testable import SankalpaCore

@Suite("Review regressions") struct ReviewRegressionTests {
    @Test func futurePracticeCanStopBeforeStart() throws {
        var item = Sankalpa.testDeclared(startDate: day(2026, 9, 22), unit: .day, timesPerPeriod: 1, now: moment(2026, 9, 21))
        try item.stop(now: moment(2026, 9, 21))
        #expect(item.state == .stopped)
        #expect(PeriodOutcomeCalculator.tally(commitment: item.commitment, lifecycle: item.lifecycle, sessions: [], range: day(2026, 9, 21)...day(2026, 9, 30), today: day(2026, 10, 1)).isEmpty)
    }
    @Test func beginCannotBackdateResume() throws {
        var item = Sankalpa.testDeclared(startDate: day(2026, 9, 21), unit: .day, timesPerPeriod: 1, now: moment(2026, 9, 21, 7))
        try item.begin(BeginTiming(now: moment(2026, 9, 21, 7)))
        try item.pause(now: moment(2026, 9, 21, 8))
        #expect(throws: LifecycleTransitionError.self) { try item.begin(BeginTiming(effectiveAt: moment(2026, 9, 21, 9), recordedAt: moment(2026, 9, 21, 12))) }
        #expect(item.state == .paused)
    }
    @Test func resumeCannotReplaceInitialBegin() {
        var item = Sankalpa.testDeclared(startDate: day(2026, 9, 21), unit: .day, timesPerPeriod: 1, now: moment(2026, 9, 21, 7))
        #expect(throws: LifecycleTransitionError.self) { try item.resume(now: moment(2026, 9, 21, 8)) }
    }
    @Test func sameDayBeginAllowsMorningSession() throws {
        var item = Sankalpa.testDeclared(startDate: day(2026, 9, 21), unit: .day, timesPerPeriod: 1, now: moment(2026, 9, 21, 12))
        try item.begin(BeginTiming(effectiveAt: moment(2026, 9, 21, 6), recordedAt: moment(2026, 9, 21, 12)))
        _ = try item.logSession(occurredAt: moment(2026, 9, 21, 7), now: moment(2026, 9, 21, 12))
    }
}
