import Foundation

/// Derives period outcomes from a commitment, a lifecycle timeline and the sessions in range.
///
/// It is a pure function of its inputs, which is why it is stateless and why the outcomes it
/// returns are never persisted.
public enum PeriodOutcomeCalculator {

    /// Evaluates every window whose *start date* falls within `range` (DD-17).
    ///
    /// - Parameter sessions: sessions covering at least the selected windows' full span. The
    ///   application layer widens its session query to those boundaries so a range that begins
    ///   partway through a week or month cannot undercount that window.
    public static func tally(
        commitment: Commitment,
        lifecycle: LifecycleTimeline,
        sessions: [Session],
        range: ClosedRange<CalendarDay>,
        today: CalendarDay
    ) -> [PeriodOutcome] {
        let windows = commitment.windowsStartingBetween(range.lowerBound, range.upperBound)
        guard !windows.isEmpty else { return [] }

        // DD-16 — a terminal transition is a reporting cutoff. The window it interrupted and every
        // later window are omitted rather than judged on partial time.
        let cutoffDay = lifecycle.terminalTransition?.effectiveAt.day
        let required = commitment.timesPerPeriod.value

        var performedByWindowIndex: [Int: Int] = [:]
        for session in sessions {
            if let window = commitment.windowContaining(session.occurredAt) {
                performedByWindowIndex[window.index, default: 0] += 1
            }
        }

        var outcomes: [PeriodOutcome] = []
        outcomes.reserveCapacity(windows.count)

        for window in windows {
            if let cutoffDay, window.end >= cutoffDay { break }

            let performed = performedByWindowIndex[window.index] ?? 0
            let standing: PeriodStanding
            if !window.isClosed(asOf: today) {
                standing = .open
            } else if lifecycle.wasPausedThroughout(window) {
                standing = .paused
            } else {
                standing = performed >= required ? .satisfied : .unsatisfied
            }

            let missed = standing == .unsatisfied ? max(0, required - performed) : 0
            outcomes.append(
                PeriodOutcome(
                    window: window,
                    required: required,
                    performed: performed,
                    missed: missed,
                    standing: standing
                )
            )
        }

        return outcomes
    }

    /// The day range of sessions the caller must load to evaluate `windows` without undercounting.
    public static func sessionRange(covering windows: [PeriodWindow]) -> ClosedRange<CalendarDay>? {
        guard let first = windows.first, let last = windows.last else { return nil }
        return first.start...last.end
    }
}
