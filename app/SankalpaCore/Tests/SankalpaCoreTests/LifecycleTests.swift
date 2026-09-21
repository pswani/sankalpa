import Testing
@testable import SankalpaCore

@Suite("Lifecycle")
struct LifecycleTests {

    private let start = day(2026, 1, 1)

    private func declared(now: CalendarMoment = moment(2026, 1, 1, 8)) -> Sankalpa {
        Sankalpa.testDeclared(startDate: start, unit: .day, timesPerPeriod: 1, periodCount: 30, now: now)
    }

    // MARK: - Transition table (S7)

    @Test("Not started may go straight to a terminal state but never to Paused")
    func notStartedTransitions() {
        let state = LifecycleState.notStarted
        #expect(state.canTransition(to: .inProgress))
        #expect(state.canTransition(to: .stopped))
        #expect(state.canTransition(to: .completedSuccessfully))
        #expect(state.canTransition(to: .completedUnsuccessfully))
        #expect(!state.canTransition(to: .paused))
        #expect(!state.canTransition(to: .notStarted))
    }

    @Test("Nothing may return to Not started")
    func noReturnToNotStarted() {
        for state in LifecycleState.allCases {
            #expect(!state.canTransition(to: .notStarted))
        }
    }

    @Test("Completed and Stopped are terminal")
    func terminalStatesAreFinal() {
        for state in [LifecycleState.completedSuccessfully, .completedUnsuccessfully, .stopped] {
            #expect(state.isTerminal)
            #expect(state.allowedTargets.isEmpty)
        }
    }

    @Test("Paused resumes to In progress and can end in any terminal state")
    func pausedTransitions() {
        let state = LifecycleState.paused
        #expect(state.canTransition(to: .inProgress))
        #expect(state.canTransition(to: .stopped))
        #expect(!state.canTransition(to: .paused))
    }

    @Test("An illegal transition is refused with the states that caused it")
    func illegalTransitionIsRefused() throws {
        var sankalpa = declared()
        #expect(throws: LifecycleTransitionError.invalidLifecycleTransition(from: .notStarted, to: .paused)) {
            try sankalpa.pause(now: moment(2026, 1, 1, 10))
        }
        try sankalpa.begin(BeginTiming(now: moment(2026, 1, 1, 10)))
        try sankalpa.stop(now: moment(2026, 1, 2, 10))
        #expect(throws: LifecycleTransitionError.invalidLifecycleTransition(from: .stopped, to: .inProgress)) {
            try sankalpa.resume(now: moment(2026, 1, 3, 10))
        }
    }

    // MARK: - Begin timing (S11, S14)

    @Test("Begin may be backdated to the start date but not before it")
    func backdatedBegin() throws {
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 1, 10), unit: .day, timesPerPeriod: 1, periodCount: 30,
            now: moment(2026, 1, 20, 9)
        )
        #expect(throws: LifecycleTransitionError.transitionBeforeStart(startDate: day(2026, 1, 10))) {
            try sankalpa.begin(
                BeginTiming(effectiveAt: moment(2026, 1, 9, 9), recordedAt: moment(2026, 1, 20, 9))
            )
        }
        try sankalpa.begin(
            BeginTiming(effectiveAt: moment(2026, 1, 12, 7), recordedAt: moment(2026, 1, 20, 9))
        )
        #expect(sankalpa.state == .inProgress)
        #expect(sankalpa.lifecycle.transitions.first?.wasBackdated == true)
    }

    @Test("Begin cannot take effect in the future")
    func beginCannotBeInTheFuture() {
        var sankalpa = declared()
        #expect(throws: LifecycleTransitionError.transitionInFuture) {
            try sankalpa.begin(
                BeginTiming(effectiveAt: moment(2026, 1, 5, 9), recordedAt: moment(2026, 1, 1, 9))
            )
        }
    }

    @Test("Every transition after Begin records the same effective and recorded time")
    func onlyBeginMayBeBackdated() throws {
        var sankalpa = declared()
        try sankalpa.begin(
            BeginTiming(effectiveAt: moment(2026, 1, 1, 6), recordedAt: moment(2026, 1, 3, 9))
        )
        try sankalpa.pause(now: moment(2026, 1, 5, 9))
        try sankalpa.resume(now: moment(2026, 1, 8, 9))
        try sankalpa.complete(.successfully, now: moment(2026, 1, 20, 9))

        let later = sankalpa.lifecycle.transitions.dropFirst()
        #expect(later.allSatisfy { $0.effectiveAt == $0.recordedAt })
        #expect(sankalpa.state == .completedSuccessfully)
    }

    // MARK: - Audit trail (S8, DD-4)

    @Test("Every transition is recorded in order with both timestamps")
    func transitionsAreAudited() throws {
        var sankalpa = declared()
        try sankalpa.begin(BeginTiming(now: moment(2026, 1, 1, 9)))
        try sankalpa.pause(now: moment(2026, 1, 4, 9))
        try sankalpa.resume(now: moment(2026, 1, 6, 9))
        try sankalpa.stop(now: moment(2026, 1, 9, 9))

        let trail = sankalpa.lifecycle.transitions
        #expect(trail.map(\.to) == [.inProgress, .paused, .inProgress, .stopped])
        #expect(trail.map(\.from) == [.notStarted, .inProgress, .paused, .inProgress])
        #expect(zip(trail, trail.dropFirst()).allSatisfy { $0.effectiveAt < $1.effectiveAt })
        #expect(sankalpa.lifecycle.terminalTransition?.to == .stopped)
    }

    // MARK: - Reconstructing state at a time

    @Test("State at a moment is reconstructed from effective times")
    func stateAtMoment() throws {
        var sankalpa = declared()
        try sankalpa.begin(BeginTiming(now: moment(2026, 1, 2, 9)))
        try sankalpa.pause(now: moment(2026, 1, 5, 9))
        try sankalpa.resume(now: moment(2026, 1, 9, 9))

        let timeline = sankalpa.lifecycle
        #expect(timeline.state(at: moment(2026, 1, 1, 12)) == .notStarted)
        #expect(timeline.state(at: moment(2026, 1, 2, 8)) == .notStarted)
        #expect(timeline.state(at: moment(2026, 1, 3, 12)) == .inProgress)
        #expect(timeline.state(at: moment(2026, 1, 6, 12)) == .paused)
        #expect(timeline.state(at: moment(2026, 1, 20, 12)) == .inProgress)
    }

    @Test("A window counts as fully paused only when no other state touched it")
    func wasPausedThroughout() throws {
        var sankalpa = Sankalpa.testDeclared(
            startDate: day(2026, 1, 1), unit: .week, timesPerPeriod: 3, periodCount: 8,
            now: moment(2026, 1, 1, 8)
        )
        try sankalpa.begin(BeginTiming(now: moment(2026, 1, 1, 9)))
        // Paused across the whole of week 2 (Jan 8–14) and part of week 3.
        try sankalpa.pause(now: moment(2026, 1, 7, 20))
        try sankalpa.resume(now: moment(2026, 1, 17, 9))

        let commitment = sankalpa.commitment
        #expect(!sankalpa.lifecycle.wasPausedThroughout(commitment.window(at: 0)!))
        #expect(sankalpa.lifecycle.wasPausedThroughout(commitment.window(at: 1)!))
        #expect(!sankalpa.lifecycle.wasPausedThroughout(commitment.window(at: 2)!))
    }
}
