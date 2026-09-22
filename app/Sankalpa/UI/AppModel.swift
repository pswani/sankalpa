import Foundation
import Observation
import SankalpaCore
import SankalpaStorage

/// The driving adapter between SwiftUI and the application layer.
///
/// It holds no domain rules. Every command goes to `SankalpaApplicationService`, and every refusal
/// comes back as a `SankalpaCommandError` whose message is shown to the user unchanged.
@MainActor
@Observable
final class AppModel {
    private let store: FileStore
    private let service: SankalpaApplicationService

    /// Everything the list and Today screens render, refreshed after each command.
    private(set) var summaries: [SankalpaSummary] = []
    /// The closed-period strip for each sankalpa, rebuilt with the summaries.
    private(set) var recentStandings: [SankalpaId: [PeriodOutcome]] = [:]
    /// The satisfied/missed count for each sankalpa, over the whole reported history.
    private(set) var tallies: [SankalpaId: PeriodTally] = [:]
    private(set) var today: CalendarDay
    /// Bumped on every refresh.
    ///
    /// Most screens read `summaries`, so observation reaches them for free. The history screens
    /// and the Journal ask the application layer a question instead, and a method call touches
    /// no observed property — so a view that has already been built has nothing to notice when
    /// the answer changes. The Journal is a tab, which means it stays alive after the first
    /// visit: without this, a session logged after that visit never appeared in it.
    private(set) var revision: Int = 0

    /// A refusal to show in an alert. Commands that have their own inline error surface return the
    /// error instead of setting this.
    var alertMessage: String?
    /// A short confirmation banner after a successful action (state 6 — success feedback).
    var confirmation: String?
    /// Changes on every confirmation, including two identical ones in a row. The banner's
    /// dismissal timer keys off this rather than the text: logging twice inside four seconds
    /// would otherwise leave the second undo offer running out the first one's clock.
    private(set) var confirmationToken: Int = 0
    /// Bumped on every successful log so views can trigger haptics without owning the state.
    private(set) var successCount: Int = 0
    /// The session the confirmation banner can still take back, if any.
    private(set) var undoableSession: SessionId?

    /// Non-nil when the store could not be opened. The whole app drops into recovery rather than
    /// showing an empty practice, which would look identical to a fresh install.
    var storageProblem: String? { store.loadError }
    /// Bumped whenever the store is re-examined, so a retry that changes nothing still reaches
    /// the recovery screen as an answer.
    private(set) var storageAttempts: Int = 0
    /// Where an unreadable file was moved to, once the user has chosen to start fresh.
    private(set) var setAsideFileURL: URL?

    /// The store file, for handing to the share sheet. Absent until something has been written.
    var exportableFileURL: URL? { store.fileExists ? store.fileURL : nil }

    init(store: FileStore, clock: SankalpaClock = SystemClock(), seedDemoData: Bool = false) {
        self.store = store
        self.service = SankalpaApplicationService(
            sankalpas: store, sessions: store, clock: clock
        )
        self.today = clock.today()
        // Demo data is opt-in and only ever seeds a genuinely new store. Seeding on "the store came
        // back empty" is how a failed load, or a deliberate Clear, silently gets overwritten.
        if seedDemoData, store.isNew {
            SampleData.seed(into: store, clock: clock)
        }
        refresh()
    }

    convenience init() {
        let wantsDemoData: Bool
        #if DEBUG
        wantsDemoData = ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        wantsDemoData = false
        #endif
        self.init(store: FileStore(fileURL: FileStore.defaultFileURL()), seedDemoData: wantsDemoData)
    }

    // MARK: - Reporting range

    /// How much history the app reports on. Ten years is the longest duration a commitment can
    /// declare, so in practice nothing a user has actually recorded falls outside it — but the
    /// reads stay bounded (DD-17) and the screens say what their range is.
    static let historyPeriodLimit = SankalpaApplicationService.historyPeriodLimit
    static let historyDays = 3_650
    /// The window the detail screen's "Recent sessions" preview covers.
    static let recentSessionDays = 120

    // MARK: - Reading

    func refresh() {
        revision += 1
        today = service.today()
        summaries = service.summaries()
        // Built once per refresh rather than per card per render. The work is small, but calling
        // into the application layer from inside a view's body is the kind of thing that stops
        // being small without anyone noticing.
        recentStandings = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, closedOutcomes(for: $0.id)) }
        )
        tallies = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, service.periodTally($0.id)) }
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

    /// Counted over the same history the Periods screen lists, so the two can never disagree.
    func periodTally(_ id: SankalpaId) -> PeriodTally {
        tallies[id] ?? service.periodTally(id)
    }

    /// Every period the app reports on, oldest first — what the Periods screen lists.
    func periodHistory(_ id: SankalpaId) -> [PeriodOutcome] {
        service.recentPeriodOutcomes(id, limit: AppModel.historyPeriodLimit)
    }

    /// True when the sankalpa is old enough that the reported history leaves some out.
    func hasPeriodsBeyondHistory(_ id: SankalpaId) -> Bool {
        service.hasPeriodsBeyond(id, limit: AppModel.historyPeriodLimit)
    }

    func lifecycleHistory(_ id: SankalpaId) -> [LifecycleTransition] {
        service.lifecycleHistory(id)
    }

    /// Recent sessions for one sankalpa, bounded by a day range rather than loading all history.
    func recentSessions(_ id: SankalpaId, days: Int = AppModel.recentSessionDays) -> [Session] {
        service.sessions(id, from: today.addingDays(-days), until: today)
    }

    func performedCount(_ id: SankalpaId, in window: PeriodWindow) -> Int {
        service.performedCount(id, in: window)
    }

    /// The newest moment a session could still be recorded for, so a picker cannot offer a time
    /// the domain will refuse.
    func latestEligibleMoment(for sankalpa: Sankalpa) -> CalendarMoment? {
        service.latestEligibleMoment(for: sankalpa, now: service.now())
    }

    func journal(days: Int = AppModel.historyDays) -> [JournalEntry] {
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
        undoableSession = nil
        do {
            try service.undoLoggedSession(sessionId)
            refresh()
            confirmation = "Session removed"
            confirmationToken += 1
        } catch {
            alertMessage = error.message
        }
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

    /// Removes everything. A cleared store stays cleared: nothing re-seeds it on the next launch.
    func clearAll() {
        do {
            try store.clear()
            refresh()
            confirmation = "Cleared"
            confirmationToken += 1
        } catch {
            alertMessage = error.message
        }
    }

    // MARK: - Recovery

    /// Tries to open the store again, for when the failure was transient.
    func retryLoadingStore() {
        store.reload()
        storageAttempts += 1
        refresh()
    }

    /// Moves an unreadable file aside and carries on with an empty store.
    ///
    /// Refusing to write over a file that will not parse is right; leaving the user with no way
    /// forward is not. The damaged bytes are renamed, never deleted, so they can still be shared
    /// out of the app afterwards.
    func startFreshPreservingUnreadableFile() {
        do {
            setAsideFileURL = try store.setAsideUnreadableFile()
            storageAttempts += 1
            refresh()
            confirmation = "Started fresh"
        } catch {
            alertMessage = "The damaged file could not be moved aside. \(error.localizedDescription)"
        }
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
        confirmationToken += 1
        successCount += 1
    }

    /// Called when the confirmation banner is dismissed.
    func clearConfirmation() {
        confirmation = nil
        undoableSession = nil
    }
}
