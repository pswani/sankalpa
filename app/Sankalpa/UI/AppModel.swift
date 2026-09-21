import Foundation
import Observation
import SankalpaCore

/// The driving adapter between SwiftUI and the application layer.
///
/// It holds no domain rules. Every command goes to `SankalpaApplicationService`, and every refusal
/// comes back as a `SankalpaCommandError` whose message is shown to the user unchanged.
@MainActor
@Observable
final class AppModel {
    private let store: FileSankalpaStore
    private let service: SankalpaApplicationService

    /// Everything the list and Today screens render, refreshed after each command.
    private(set) var summaries: [SankalpaSummary] = []
    /// The closed-period strip for each sankalpa, rebuilt with the summaries.
    private(set) var recentStandings: [SankalpaId: [PeriodOutcome]] = [:]
    private(set) var today: CalendarDay

    /// A refusal to show in an alert. Commands that have their own inline error surface return the
    /// error instead of setting this.
    var alertMessage: String?
    /// A short confirmation banner after a successful action (state 6 — success feedback).
    var confirmation: String?
    /// Bumped on every successful log so views can trigger haptics without owning the state.
    private(set) var successCount: Int = 0
    /// The session the confirmation banner can still take back, if any.
    private(set) var undoableSession: SessionId?

    init(store: FileSankalpaStore, clock: SankalpaClock = SystemClock(), seedIfEmpty: Bool = true) {
        self.store = store
        self.service = SankalpaApplicationService(
            sankalpas: store, sessions: store, clock: clock
        )
        self.today = clock.today()
        if seedIfEmpty, store.isEmpty {
            SampleData.seed(into: store, clock: clock)
        }
        refresh()
    }

    convenience init() {
        self.init(store: FileSankalpaStore(fileURL: FileSankalpaStore.defaultFileURL()))
    }

    // MARK: - Reading

    func refresh() {
        today = service.today()
        summaries = service.summaries()
        // Built once per refresh rather than per card per render. The work is small, but calling
        // into the application layer from inside a view's body is the kind of thing that stops
        // being small without anyone noticing.
        recentStandings = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, closedOutcomes(for: $0.id)) }
        )
    }

    private func closedOutcomes(for id: SankalpaId, limit: Int = 7) -> [PeriodOutcome] {
        let closed = service.recentPeriodOutcomes(id, limit: limit + 4)
            .filter { $0.standing != .open }
        return Array(closed.suffix(limit))
    }

    var activeSummaries: [SankalpaSummary] { summaries.filter { !$0.state.isTerminal } }

    func summary(_ id: SankalpaId) -> SankalpaSummary? {
        summaries.first { $0.id == id }
    }

    /// Oldest first, which is the order a timeline reads in. Views that want newest first reverse
    /// it themselves.
    func recentPeriodOutcomes(_ id: SankalpaId, limit: Int = 14) -> [PeriodOutcome] {
        service.recentPeriodOutcomes(id, limit: limit)
    }

    /// Only periods that have closed, newest last — the strip on a card shows judged history, not
    /// the period still in progress.
    func recentClosedOutcomes(_ id: SankalpaId) -> [PeriodOutcome] {
        recentStandings[id] ?? []
    }

    func periodTally(_ id: SankalpaId) -> PeriodTally {
        service.periodTally(id)
    }

    func lifecycleHistory(_ id: SankalpaId) -> [LifecycleTransition] {
        service.lifecycleHistory(id)
    }

    /// Recent sessions for one sankalpa, bounded by a day range rather than loading all history.
    func recentSessions(_ id: SankalpaId, days: Int = 120) -> [Session] {
        service.sessions(id, from: today.addingDays(-days), until: today)
    }

    func performedCount(_ id: SankalpaId, in window: PeriodWindow) -> Int {
        service.performedCount(id, in: window)
    }

    func journal(days: Int = 120) -> [JournalEntry] {
        service.journal(from: today.addingDays(-days), until: today)
    }

    func now() -> CalendarMoment { service.now() }

    // MARK: - Commands with inline error reporting

    /// Returns `nil` on success, or the refusal for the form to show next to the field it concerns.
    func declare(_ declaration: Declaration) -> SankalpaCommandError? {
        do {
            try service.declareSankalpa(declaration)
            succeed("Sankalpa declared")
            return nil
        } catch {
            return error
        }
    }

    func logSession(_ id: SankalpaId, occurredAt: CalendarMoment) -> SankalpaCommandError? {
        do {
            let session = try service.logSession(id, occurredAt: occurredAt)
            undoableSession = session.id
            succeed("Session logged")
            return nil
        } catch {
            return error
        }
    }

    /// Takes back the session just logged. Cleared as soon as the confirmation banner goes away, so
    /// undo is only ever offered for the action the user can still see.
    func undoLastSession() {
        guard let sessionId = undoableSession else { return }
        service.undoLoggedSession(sessionId)
        undoableSession = nil
        refresh()
        confirmation = "Session removed"
    }

    // MARK: - Commands with alert error reporting

    func begin(_ id: SankalpaId, effectiveAt: CalendarMoment? = nil) {
        perform("Sankalpa begun") { try service.beginSankalpa(id, effectiveAt: effectiveAt) }
    }

    func pause(_ id: SankalpaId) {
        perform("Paused") { try service.pauseSankalpa(id) }
    }

    func resume(_ id: SankalpaId) {
        perform("Resumed") { try service.resumeSankalpa(id) }
    }

    func complete(_ id: SankalpaId, outcome: CompletionOutcome) {
        let confirmation = outcome == .successfully
            ? "Completed successfully"
            : "Completed unsuccessfully"
        perform(confirmation) { try service.completeSankalpa(id, outcome: outcome) }
    }

    func stop(_ id: SankalpaId) {
        perform("Stopped") { try service.stopSankalpa(id) }
    }

    /// Clears the sample data this app seeds on a first launch.
    func clearAll() {
        store.replaceAll(sankalpas: [], sessions: [])
        refresh()
        confirmation = "Cleared"
    }

    // MARK: - Plumbing

    private func perform(_ confirmationText: String, _ command: () throws -> Void) {
        undoableSession = nil
        do {
            try command()
            succeed(confirmationText)
        } catch let error as SankalpaCommandError {
            alertMessage = error.message
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func succeed(_ text: String) {
        refresh()
        confirmation = text
        successCount += 1
    }

    /// Called when the confirmation banner is dismissed.
    func clearConfirmation() {
        confirmation = nil
        undoableSession = nil
    }
}
