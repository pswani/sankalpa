import Foundation

/// The read side. Every query returns data and changes nothing, and every query that touches
/// session history is day-range bounded (DD-17).
extension SankalpaApplicationService {

    // MARK: - Listing

    /// `FindSankalpas` — summaries for the list screen, ordered so the sankalpas the user can still
    /// act on come first.
    public func summaries() -> [SankalpaSummary] {
        allSankalpas()
            .map(summary(for:))
            .sorted(by: SankalpaApplicationService.listOrder)
    }

    /// The Today board: the sankalpas that can be acted on right now, most urgent first.
    public func activeSummaries() -> [SankalpaSummary] {
        summaries().filter { !$0.state.isTerminal }
    }

    public func summary(_ id: SankalpaId) -> SankalpaSummary? {
        findSankalpa(id).map(summary(for:))
    }

    private func summary(for sankalpa: Sankalpa) -> SankalpaSummary {
        SankalpaSummary(
            sankalpa: sankalpa,
            currentPeriod: currentPeriodProgress(for: sankalpa),
            totalSessions: totalSessionCount(sankalpa.id)
        )
    }

    /// Whatever still wants action today comes first, then what is already done for this period,
    /// then paused, then waiting to begin, then finished.
    private static func listOrder(_ lhs: SankalpaSummary, _ rhs: SankalpaSummary) -> Bool {
        let (lhsRank, rhsRank) = (rank(lhs), rank(rhs))
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        if lhs.commitment.startDate != rhs.commitment.startDate {
            // A sankalpa waiting to begin is ordered by how soon it starts; everything else by how
            // recently it did.
            return lhsRank == notStartedRank
                ? lhs.commitment.startDate < rhs.commitment.startDate
                : lhs.commitment.startDate > rhs.commitment.startDate
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static let notStartedRank = 3

    private static func rank(_ summary: SankalpaSummary) -> Int {
        switch summary.state {
        case .inProgress:
            // No current period means today falls outside the commitment, so there is nothing to
            // do even though it is still In progress.
            guard let period = summary.currentPeriod else { return 1 }
            return period.isSatisfied ? 1 : 0
        case .paused:
            return 2
        case .notStarted:
            return notStartedRank
        case .completedSuccessfully, .completedUnsuccessfully, .stopped:
            return 4
        }
    }

    // MARK: - Current period

    /// Progress through the window the user is in today. Absent when today falls outside the
    /// commitment's coverage — reaching the end date does not change the lifecycle (S15), so a
    /// finished-but-still-In-progress sankalpa simply has no current period.
    public func currentPeriodProgress(for sankalpa: Sankalpa) -> CurrentPeriodProgress? {
        let today = today()
        guard let window = sankalpa.commitment.windowContaining(today) else { return nil }
        let performed = sessionsInRange(sankalpa.id, from: window.start, until: window.end).count
        return CurrentPeriodProgress(
            window: window,
            required: sankalpa.commitment.timesPerPeriod.value,
            performed: performed
        )
    }

    /// How many sessions have been performed inside one window — used to preview what logging a
    /// backdated session would do.
    public func performedCount(_ id: SankalpaId, in window: PeriodWindow) -> Int {
        sessionsInRange(id, from: window.start, until: window.end).count
    }

    // MARK: - Period outcomes

    /// `GetPeriodOutcomes` — windows whose start date falls in `from...until`.
    public func periodOutcomes(
        _ id: SankalpaId,
        from: CalendarDay,
        until: CalendarDay
    ) -> [PeriodOutcome] {
        guard let sankalpa = findSankalpa(id) else { return [] }
        return outcomes(for: sankalpa, range: from...until)
    }

    /// The most recent `limit` windows, oldest first. Anchored to the terminal transition when
    /// there is one, so a stopped sankalpa still shows the periods it was judged on (DD-16).
    public func recentPeriodOutcomes(_ id: SankalpaId, limit: Int = 12) -> [PeriodOutcome] {
        guard limit > 0, let sankalpa = findSankalpa(id) else { return [] }
        let commitment = sankalpa.commitment

        var anchor = sankalpa.lifecycle.terminalTransition
            .map { $0.effectiveAt.day.addingDays(-1) } ?? today()
        anchor = max(anchor, commitment.startDate)
        if let endDate = commitment.endDate { anchor = min(anchor, endDate) }

        guard let anchorWindow = commitment.windowContaining(anchor) else { return [] }
        let firstIndex = max(0, anchorWindow.index - limit + 1)
        guard let firstWindow = commitment.window(at: firstIndex) else { return [] }

        return outcomes(for: sankalpa, range: firstWindow.start...anchorWindow.start)
    }

    public func periodTally(_ id: SankalpaId, limit: Int = 520) -> PeriodTally {
        PeriodTally(outcomes: recentPeriodOutcomes(id, limit: limit))
    }

    /// Widens the session query to the selected windows' real boundaries so a range beginning
    /// partway through a week or month cannot undercount that window (DD-17).
    private func outcomes(
        for sankalpa: Sankalpa,
        range: ClosedRange<CalendarDay>
    ) -> [PeriodOutcome] {
        let windows = sankalpa.commitment.windowsStartingBetween(range.lowerBound, range.upperBound)
        guard let sessionRange = PeriodOutcomeCalculator.sessionRange(covering: windows) else {
            return []
        }
        return PeriodOutcomeCalculator.tally(
            commitment: sankalpa.commitment,
            lifecycle: sankalpa.lifecycle,
            sessions: sessionsInRange(
                sankalpa.id,
                from: sessionRange.lowerBound,
                until: sessionRange.upperBound
            ),
            range: range,
            today: today()
        )
    }

    // MARK: - History

    /// `GetSessions`
    public func sessions(
        _ id: SankalpaId,
        from: CalendarDay,
        until: CalendarDay
    ) -> [Session] {
        sessionsInRange(id, from: from, until: until)
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    /// `GetLifecycleHistory` — newest first, which is the order the audit trail is read in.
    public func lifecycleHistory(_ id: SankalpaId) -> [LifecycleTransition] {
        findSankalpa(id)?.lifecycle.transitions.reversed() ?? []
    }

    /// The cross-sankalpa journal of performed sessions, newest first.
    public func journal(from: CalendarDay, until: CalendarDay) -> [JournalEntry] {
        let titles = Dictionary(
            uniqueKeysWithValues: allSankalpas().map { ($0.id, $0) }
        )
        return sessionsInRange(from: from, until: until)
            .compactMap { session in
                guard let sankalpa = titles[session.sankalpaId] else { return nil }
                return JournalEntry(
                    session: session,
                    sankalpaTitle: sankalpa.title.value,
                    actionType: sankalpa.actionType
                )
            }
            .sorted { $0.occurredAt > $1.occurredAt }
    }
}
