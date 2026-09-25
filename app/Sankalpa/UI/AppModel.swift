import Foundation
import Observation
import SankalpaCore
import SankalpaStorage

/// The driving adapter between SwiftUI and the Sankalpa service.
///
/// It holds no domain rules. Every command goes to `RemoteSankalpaService`, which sends it to the
/// service — the authority on what is allowed — and every refusal comes back as a
/// `SankalpaCommandError` whose message is shown to the user unchanged.
///
/// Reads are answered from the snapshot the last refresh returned, so the screens stay
/// synchronous: a list row asks a question and gets an answer, rather than each row owning a
/// request in flight. What that costs is staleness between refreshes, which is why every command
/// refreshes and why the screens offer pull-to-refresh.
///
/// That snapshot outlives the connection. It is kept on the phone, so the practice is still there
/// to read when the service is not — and a session logged while it is away is held until there is
/// somewhere to send it. `RemoteSankalpaService` owns both; this type only reports what it is
/// holding, so the screens can say when they are showing a copy.
@MainActor
@Observable
final class AppModel {
    struct RepeatLogProposal: Identifiable {
        let id = UUID()
        let sankalpaTitle: String
    }

    private let remote: RemoteSankalpaService
    private let credentials = ServiceCredentialStore()
    private(set) var apiToken: String

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
    /// How many session creates or deletions are not yet finalized by the service.
    private(set) var pendingSessionCount = 0
    private(set) var processingSankalpas: Set<SankalpaId> = []
    /// True when what is on screen came from the phone's copy rather than from the service just
    /// now, so a screen can say the practice may be behind.
    private(set) var isShowingCachedPractice = false
    /// The assistant is intentionally unavailable unless the latest complete refresh proved that
    /// the service can be reached. Cached practice remains useful offline; conversation does not.
    private(set) var isServiceReachable = false

    /// A refusal to show in an alert. Commands that have their own inline error surface return the
    /// error instead of setting this.
    var alertMessage: String?
    private var alertCarriesReconciliationNotice = false
    /// What the alert is about. A rule the user ran into and a service that is not answering are
    /// different kinds of news, and "That is not allowed" is wrong for the second.
    private(set) var alertTitle: String = AppModel.refusalTitle
    static let refusalTitle = "That is not allowed"
    static let unreachableTitle = "Not connected"
    /// A short confirmation banner after a successful action (state 6 — success feedback).
    var confirmation: String?
    /// Changes on every confirmation, including two identical ones in a row. The banner's
    /// dismissal timer keys off this rather than the text: logging twice inside four seconds
    /// would otherwise leave the second banner running out the first one's clock.
    private(set) var confirmationToken: Int = 0
    /// Bumped on every successful log so views can trigger haptics without owning the state.
    private(set) var successCount: Int = 0
    private(set) var undoReceipt: SessionReceipt?
    var repeatLogProposal: RepeatLogProposal?
    private var repeatContinuation: CheckedContinuation<Bool, Never>?

    /// Non-nil when the service has never been reached, so there is nothing at all to show. The
    /// whole app drops into recovery rather than showing an empty practice, which would look
    /// identical to a first run with nothing declared.
    ///
    /// Once one refresh has succeeded this stays `nil` even if a later one fails: a stale snapshot
    /// is worth more than a blank screen, and the failure is reported as an alert instead.
    ///
    /// It is stored here rather than read through to `RemoteSankalpaService`, which is not
    /// observable: a computed property over a plain reference gives SwiftUI nothing to invalidate,
    /// so the app would sit on the empty state this screen exists to replace.
    private(set) var connectionProblem: String?

    private let locations: ServiceLocationStore

    init(remote: RemoteSankalpaService, locations: ServiceLocationStore = ServiceLocationStore()) {
        self.remote = remote
        self.locations = locations
        self.apiToken = credentials.load()
        self.today = remote.today()
        // The cache may already have something to show, so the first frame is not empty while the
        // service is being asked.
        rebuild()
        connectionProblem = remote.hasLoaded ? nil : remote.refreshFailure
    }

    convenience init() {
        #if DEBUG
        // A UI run gets a practice that starts from nothing, the way a first install does. Both
        // files are built to survive, so only a test ever asks for this.
        if ProcessInfo.processInfo.arguments.contains("-resetCache") {
            PracticeCache.removeEverything()
        }
        #endif
        let locations = ServiceLocationStore()
        let credential = ServiceCredentialStore().load()
        self.init(
            remote: RemoteSankalpaService(
                location: locations.current,
                clock: SystemClock(),
                transport: AppModel.transport(),
                bearerToken: credential
            ),
            locations: locations
        )
    }

    /// The real one, unless a UI run has asked the app to behave as though the service were out of
    /// reach. Nothing inside the simulator can stop the service the test is running against, so
    /// driving the offline screens through the interface needs this one hook — and like every
    /// other test hook here, it is compiled out of release builds.
    private static func transport() -> APITransport {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-offline") {
            return UnreachableTransport()
        }
        #endif
        return URLSessionTransport()
    }

    /// Where the service is, as the app is currently configured.
    var serviceLocation: ServiceLocation { remote.serviceLocation }
    var assistantCapability: AssistantCapability? { remote.assistantCapability }
    var reliabilityProblem: String? { remote.reliabilityProblem }
    var pendingCreates: [PendingSession] { remote.pending }
    var pendingDeletions: [PendingSessionDeletion] { remote.pendingDeletions }
    var quarantinedCreateIds: Set<SessionId> { remote.quarantinedCreateIds }
    /// True when an environment variable is deciding, so the settings screen can say the value it
    /// shows is not the one in use rather than appearing to ignore what was typed.
    var serviceLocationIsOverridden: Bool { locations.isOverriddenByEnvironment }

    /// Points the app at a different computer and reloads from it.
    ///
    /// The cached practice belongs to the old one, so it goes. A location change is refused while
    /// session changes are pending, because those changes are bound to one service instance.
    func useService(at location: ServiceLocation) async {
        guard await remote.relocate(to: location) else {
            alertCarriesReconciliationNotice = false
            alertTitle = AppModel.refusalTitle
            alertMessage = remote.refreshFailure
            return
        }
        locations.save(location)
        finishSync()
    }

    @discardableResult
    func useAPIToken(_ token: String) async -> Bool {
        guard credentials.save(token) else { return false }
        apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        remote.useBearerToken(apiToken)
        await refresh()
        return true
    }

    // MARK: - Reporting range

    /// Bounded ranges for derived period and journal reporting. Complete session history is loaded
    /// separately so every session remains available for correction.
    static let historyPeriodLimit = SankalpaApplicationService.historyPeriodLimit
    static let historyDays = 3_650
    /// The window the detail screen's "Recent sessions" preview covers.
    static let recentSessionDays = 120

    // MARK: - Reading

    /// Sends anything waiting, re-reads everything, and rebuilds the derived screens' data.
    ///
    /// This is what every entry point wants — launch, coming back to the foreground, pull to
    /// refresh — because a session logged while the service was away has to reach it at the first
    /// opportunity, and that opportunity is exactly when the app next tries to read.
    func refresh() async {
        await remote.sync()
        finishSync()
    }

    private func finishSync() {
        if remote.hasLoaded {
            // There is still a practice to show, and the offline strip is already saying it may
            // be behind. An alert on top of that interrupts the user to repeat what is on screen,
            // every time the app comes back to the foreground out of range.
            connectionProblem = nil
        } else {
            connectionProblem = remote.refreshFailure
        }
        // A session the service refused when it was finally sent is news the user has to get:
        // they were told it was logged, and it is about to disappear from the screen.
        let rejections = remote.reconciliationNotices
        if !rejections.isEmpty {
            alertTitle = AppModel.refusalTitle
            alertMessage = rejections.joined(separator: "\n\n")
            alertCarriesReconciliationNotice = true
        }
        rebuild()
    }

    /// Rebuilds everything derived from the snapshot. Separate from `refresh()` so a day rollover
    /// can re-derive the current period without another round trip.
    func rebuild() {
        revision += 1
        today = remote.today()
        pendingSessionCount = remote.pendingChangeCount
        isShowingCachedPractice = remote.isShowingCachedPractice
        isServiceReachable = remote.isServiceReachable
        summaries = remote.queries.summaries()
        // Built once per refresh rather than per card per render. The work is small, but calling
        // into the application layer from inside a view's body is the kind of thing that stops
        // being small without anyone noticing.
        recentStandings = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, closedOutcomes(for: $0.id)) }
        )
        tallies = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.id, remote.queries.periodTally($0.id)) }
        )
    }

    private func closedOutcomes(for id: SankalpaId, limit: Int = 7) -> [PeriodOutcome] {
        let closed = remote.queries.recentPeriodOutcomes(id, limit: limit + 4)
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
        remote.queries.recentPeriodOutcomes(id, limit: limit)
    }

    /// Only periods that have closed, newest last — the strip on a card shows judged history, not
    /// the period still in progress.
    func recentClosedOutcomes(_ id: SankalpaId) -> [PeriodOutcome] {
        recentStandings[id] ?? []
    }

    /// Counted over the same history the Periods screen lists, so the two can never disagree.
    func periodTally(_ id: SankalpaId) -> PeriodTally {
        tallies[id] ?? remote.queries.periodTally(id)
    }

    /// Every period the app reports on, oldest first — what the Periods screen lists.
    func periodHistory(_ id: SankalpaId) -> [PeriodOutcome] {
        remote.queries.recentPeriodOutcomes(id, limit: AppModel.historyPeriodLimit)
    }

    /// True when the sankalpa is old enough that the reported history leaves some out.
    func hasPeriodsBeyondHistory(_ id: SankalpaId) -> Bool {
        remote.queries.hasPeriodsBeyond(id, limit: AppModel.historyPeriodLimit)
    }

    func lifecycleHistory(_ id: SankalpaId) -> [LifecycleTransition] {
        remote.queries.lifecycleHistory(id)
    }

    /// Recent sessions for one sankalpa, bounded by a day range rather than loading all history.
    func recentSessions(_ id: SankalpaId, days: Int = AppModel.recentSessionDays) -> [Session] {
        remote.queries.sessions(id, from: today.addingDays(-days), until: today)
    }

    /// Every locally known session for permanent correction in the Sessions screen.
    func allSessions(_ id: SankalpaId) -> [Session] {
        remote.allSessions(for: id)
    }

    func isProcessingSession(for id: SankalpaId) -> Bool { processingSankalpas.contains(id) }

    func performedCount(_ id: SankalpaId, in window: PeriodWindow) -> Int {
        remote.queries.performedCount(id, in: window)
    }

    /// The newest moment a session could still be recorded for, so a picker cannot offer a time
    /// the domain will refuse.
    func latestEligibleMoment(for sankalpa: Sankalpa) -> CalendarMoment? {
        remote.queries.latestEligibleMoment(for: sankalpa, now: remote.now())
    }

    func journal(days: Int = AppModel.historyDays) -> [JournalEntry] {
        remote.queries.journal(from: today.addingDays(-days), until: today)
    }

    func now() -> CalendarMoment { remote.now() }

    // MARK: - Commands with inline error reporting

    /// Returns `nil` on success, or the refusal for the form to show next to the field it concerns.
    func declare(_ declaration: Declaration) async -> SankalpaCommandError? {
        if let error = await remote.declare(declaration) { return error }
        succeed("Sankalpa declared")
        return nil
    }

    func logSession(_ id: SankalpaId, occurredAt: CalendarMoment) async -> SankalpaCommandError? {
        guard !processingSankalpas.contains(id) else { return nil }
        processingSankalpas.insert(id)
        defer { processingSankalpas.remove(id) }

        if remote.shouldConfirmRepeat(for: id) {
            guard repeatContinuation == nil else {
                return .storage(.unavailable(
                    "Finish the current session confirmation before logging another session."
                ))
            }
            let confirmed = await withCheckedContinuation { continuation in
                repeatContinuation = continuation
                repeatLogProposal = RepeatLogProposal(
                    sankalpaTitle: summary(id)?.title ?? "this sankalpa"
                )
            }
            guard confirmed else { return nil }
        }

        switch await remote.logSessionCommand(id, occurredAt: occurredAt) {
        case .accepted(let receipt):
            succeed("Session logged", undo: receipt)
            return nil
        case .pending(let receipt):
            succeed("Session saved — waiting to send", undo: receipt)
            return nil
        case .rejected(let error):
            rebuild()
            return error
        }
    }

    /// Quick-log entry points have no inline form to carry a refusal, so route it to the shared
    /// alert instead of silently discarding the rejected status.
    func logSessionAndReport(_ id: SankalpaId, occurredAt: CalendarMoment) async {
        if let error = await logSession(id, occurredAt: occurredAt) {
            report(error)
            rebuild()
        }
    }

    func resolveRepeatLog(confirmed: Bool) {
        let continuation = repeatContinuation
        repeatContinuation = nil
        repeatLogProposal = nil
        continuation?.resume(returning: confirmed)
    }

    func undoLastSession() {
        guard let receipt = undoReceipt else { return }
        undoReceipt = nil
        Task { await deleteSession(receipt.session, isUndo: true) }
    }

    func deleteSession(_ session: Session, isUndo: Bool = false) async {
        switch await remote.deleteSession(session) {
        case .accepted:
            succeed(isUndo ? "Session undone" : "Session deleted")
        case .pending:
            succeed(isUndo ? "Session removed — deletion pending" : "Session hidden — deletion pending")
        case .rejected(let error):
            report(error)
            rebuild()
        }
    }

    // MARK: - Commands with alert error reporting

    func begin(_ id: SankalpaId, effectiveAt: CalendarMoment? = nil) {
        perform("Sankalpa begun") { await self.remote.begin(id, effectiveAt: effectiveAt) }
    }

    func pause(_ id: SankalpaId) {
        perform("Paused") { await self.remote.pause(id) }
    }

    func resume(_ id: SankalpaId) {
        perform("Resumed") { await self.remote.resume(id) }
    }

    func complete(_ id: SankalpaId, outcome: CompletionOutcome) {
        let confirmation = outcome == .successfully
            ? "Completed successfully"
            : "Completed unsuccessfully"
        perform(confirmation) { await self.remote.complete(id, outcome: outcome) }
    }

    func stop(_ id: SankalpaId) {
        perform("Stopped") { await self.remote.stop(id) }
    }

    // MARK: - Recovery

    /// Tries the service again, for when it was starting up or the network was briefly away.
    func retryConnection() async {
        await refresh()
    }

    func discardUnrecoverableSessionChanges() {
        if remote.discardUnrecoverableSessionChanges() {
            rebuild()
            succeed("Preserved session changes discarded")
        } else {
            alertTitle = AppModel.unreachableTitle
            alertMessage = remote.refreshFailure
        }
    }

    // MARK: - Plumbing

    /// Lifecycle commands are fired from buttons that do not wait for an answer, so they keep a
    /// synchronous signature and report a refusal through the alert. The work still happens on a
    /// task; only the call site is spared knowing it.
    private func perform(
        _ confirmationText: String,
        _ command: @escaping () async -> SankalpaCommandError?
    ) {
        Task {
            if let error = await command() {
                report(error)
                rebuild()
                return
            }
            succeed(confirmationText)
        }
    }

    /// The command already refreshed the snapshot, so this only re-derives and announces.
    private func succeed(_ text: String, undo: SessionReceipt? = nil) {
        rebuild()
        undoReceipt = undo
        confirmation = text
        confirmationToken += 1
        successCount += 1
    }

    /// Shows a refusal, titled for what kind of refusal it is.
    private func report(_ error: SankalpaCommandError) {
        alertCarriesReconciliationNotice = false
        if case .storage = error {
            alertTitle = AppModel.unreachableTitle
        } else {
            alertTitle = AppModel.refusalTitle
        }
        alertMessage = error.message
    }

    /// Called when the confirmation banner is dismissed.
    func clearConfirmation() {
        confirmation = nil
        undoReceipt = nil
    }

    func dismissAlert() {
        alertMessage = nil
        if alertCarriesReconciliationNotice {
            remote.acknowledgeReconciliationNotices()
            alertCarriesReconciliationNotice = false
        }
    }
}

#if DEBUG
/// Answers every request the way a service that is not there does, so a UI run can drive the
/// offline screens. Debug only, and reachable only from the `-offline` launch argument.
private struct UnreachableTransport: APITransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}
#endif
