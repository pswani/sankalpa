import Foundation

/// The transition history. It satisfies the audit requirement and is also the only thing that can
/// answer "was this sankalpa In progress when that session happened?" and "was this whole window
/// Paused?" (DD-4).
public struct LifecycleTimeline: Hashable, Codable, Sendable {
    public private(set) var current: LifecycleState
    public private(set) var transitions: [LifecycleTransition]

    public init() {
        self.current = .notStarted
        self.transitions = []
    }

    public init(current: LifecycleState, transitions: [LifecycleTransition]) {
        self.current = current
        self.transitions = transitions
    }

    // MARK: - Recording

    /// S7, S11, S14 — validates the transition table, then the timing rules, then appends.
    public mutating func record(
        to target: LifecycleState,
        effectiveAt: CalendarMoment,
        recordedAt: CalendarMoment,
        commitmentStart: CalendarDay
    ) throws(LifecycleTransitionError) {
        guard current.canTransition(to: target) else {
            throw .invalidLifecycleTransition(from: current, to: target)
        }
        guard effectiveAt <= recordedAt else {
            throw .transitionInFuture
        }
        // The start date bounds when a sankalpa may be *acted on*, so it gates entering In
        // progress. Ending one early is always allowed: a sankalpa declared for next week can be
        // stopped today, and simply has no evaluated periods.
        guard target.isTerminal || effectiveAt.day >= commitmentStart else {
            throw .transitionBeforeStart(startDate: commitmentStart)
        }
        // S14 — only the first transition, Not started → In progress, may separate its effective
        // time from when it was recorded. Everything else takes effect when the user performs it.
        guard effectiveAt == recordedAt || (current == .notStarted && target == .inProgress) else {
            throw .invalidLifecycleTransition(from: current, to: target)
        }
        // A change must land after everything already recorded. For a backdated Begin that is
        // the user's choice to correct; for every other transition it means the device clock now
        // reads earlier than it did — travelling west, or the hour daylight saving gives back —
        // so it is reported as the clock problem it is rather than as an illegal transition.
        if let last = transitions.last, effectiveAt < last.effectiveAt {
            throw .transitionOutOfOrder(lastRecorded: last.effectiveAt)
        }

        transitions.append(
            LifecycleTransition(
                from: current,
                to: target,
                effectiveAt: effectiveAt,
                recordedAt: recordedAt
            )
        )
        current = target
    }

    // MARK: - Reconstruction

    /// The state the sankalpa was in at `moment`, from the effective times.
    public func state(at moment: CalendarMoment) -> LifecycleState {
        var state = LifecycleState.notStarted
        for transition in transitions where transition.effectiveAt <= moment {
            state = transition.to
        }
        return state
    }

    /// S10 — the lifecycle half of session eligibility.
    public func wasInProgress(at moment: CalendarMoment) -> Bool {
        state(at: moment) == .inProgress
    }

    /// S13 — true only when the sankalpa was Paused for the window's entire span. A window with any
    /// In progress time in it is evaluated normally (DD-14).
    public func wasPausedThroughout(_ window: PeriodWindow) -> Bool {
        guard state(at: window.firstMoment) == .paused else { return false }
        return !transitions.contains {
            $0.effectiveAt > window.firstMoment && $0.effectiveAt <= window.lastMoment
        }
    }

    /// The transition into a terminal state, if the user has made one. It is the reporting cutoff
    /// for period outcomes (DD-16).
    public var terminalTransition: LifecycleTransition? {
        transitions.last { $0.to.isTerminal }
    }

    public var beganAt: CalendarMoment? {
        transitions.first { $0.to == .inProgress }?.effectiveAt
    }

    public func canTransition(to target: LifecycleState) -> Bool {
        current.canTransition(to: target)
    }
}
