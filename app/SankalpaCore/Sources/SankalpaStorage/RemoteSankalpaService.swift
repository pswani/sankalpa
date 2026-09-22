import Foundation
import SankalpaCore

/// The sankalpas and sessions the app is currently showing, held in memory so the read side can
/// stay synchronous.
///
/// It holds two things that are read as one. The **server's** sankalpas and sessions are what the
/// last refresh returned. The **pending** sessions were logged on this phone while the service was
/// out of reach, and have not reached it yet. Every read merges them, because a session the user
/// just logged has to count towards today's period whether or not the service has heard about it.
///
/// It is a repository the app only ever reads. Commands do not go through it — they go to the
/// service, or to the outbox — so its `save` methods refuse rather than pretend. The conformance
/// exists so the query surface in `SankalpaApplicationService` can run unchanged.
final class SnapshotStore: SankalpaRepository, SessionRepository {
    private var sankalpas: [Sankalpa] = []
    private var serverSessions: [Session] = []
    private var pendingSessions: [Session] = []
    private var counts: [SankalpaId: Int] = [:]

    func replace(sankalpas: [Sankalpa], sessions: [Session], counts: [SankalpaId: Int]) {
        self.sankalpas = sankalpas
        self.serverSessions = sessions
        self.counts = counts
    }

    /// The counts the service reported, plus whatever is still waiting to reach it.
    func replacePending(_ pending: [PendingSession]) {
        pendingSessions = pending.map(\.session)
    }

    private var sessions: [Session] { serverSessions + pendingSessions }

    var isEmpty: Bool { sankalpas.isEmpty && sessions.isEmpty }

    // MARK: - SankalpaRepository

    func all() -> [Sankalpa] { sankalpas }

    func find(_ id: SankalpaId) -> Sankalpa? { sankalpas.first { $0.id == id } }

    func save(_ sankalpa: Sankalpa) throws(PersistenceError) {
        throw .unavailable(Self.writesGoToTheService)
    }

    // MARK: - SessionRepository

    func save(_ session: Session) throws(PersistenceError) {
        throw .unavailable(Self.writesGoToTheService)
    }

    @discardableResult
    func delete(_ sessionId: SessionId) throws(PersistenceError) -> Bool {
        throw .unavailable(Self.writesGoToTheService)
    }

    func sessions(for sankalpaId: SankalpaId, from: CalendarDay, until: CalendarDay) -> [Session] {
        guard from <= until else { return [] }
        return sessions.filter {
            $0.sankalpaId == sankalpaId && $0.occurredAt.day >= from && $0.occurredAt.day <= until
        }
    }

    func sessions(from: CalendarDay, until: CalendarDay) -> [Session] {
        guard from <= until else { return [] }
        return sessions.filter { $0.occurredAt.day >= from && $0.occurredAt.day <= until }
    }

    func totalCount(for sankalpaId: SankalpaId) -> Int {
        (counts[sankalpaId] ?? 0) + pendingSessions.count { $0.sankalpaId == sankalpaId }
    }

    private static let writesGoToTheService =
        "Changes are saved by the Sankalpa service, not on this device."
}

/// The app's way in to a server-backed practice, with a copy on the phone so it still works when
/// the service is out of reach.
///
/// Three rules decide everything here:
///
/// 1. **The service owns the rules.** Every command goes to it, and it is the only thing that can
///    say yes. Reads are answered from the snapshot the last refresh returned, through the same
///    `SankalpaApplicationService` query surface the screens were built against — which is what
///    keeps the derived reads (period outcomes, the journal, list ordering) that the API
///    deliberately does not expose (05-application-layer).
/// 2. **The service wins.** A refresh replaces the cached practice outright rather than merging
///    into it. Nothing on the phone can contradict what the service says about a sankalpa.
/// 3. **Except what the service has not seen yet.** A session logged while the service was away
///    lives in an outbox, counts towards the period immediately, and is sent as soon as there is
///    something to send it to. If the service then refuses it, rule 2 applies: it is dropped and
///    the person is told.
///
/// Only session logging works offline. Lifecycle transitions do not: queuing them would need
/// ordering and backdating rules the requirements do not settle, and "the service wins" cannot
/// reconcile a queued Pause against a service that has moved on. They are refused with a clear
/// reason instead.
@MainActor
public final class RemoteSankalpaService {
    private var client: SankalpaAPIClient
    private let transport: APITransport
    private let store = SnapshotStore()
    private let clock: SankalpaClock
    private let cache: PracticeCache
    private var location: ServiceLocation

    /// The read side. Only its queries are meaningful here: its command methods would write
    /// through `SnapshotStore`, which refuses. Commands live on this type instead.
    public let queries: SankalpaApplicationService

    /// Why the last refresh failed, or `nil` when the snapshot is current.
    public private(set) var refreshFailure: String?
    /// False until there is something to show — a refresh that worked, or a cache from one that
    /// did. It is what separates "nothing to show at all" from "showing what we have".
    public private(set) var hasLoaded = false
    /// True when the snapshot came from the cache rather than from the service just now, so the
    /// screens can say the practice may be behind.
    public private(set) var isShowingCachedPractice = false
    /// Sessions logged on this phone that the service has not accepted yet.
    public private(set) var pending: [PendingSession] = []
    /// Sessions the service refused when they were finally sent, in its own words. Read once and
    /// cleared, because this is news rather than state.
    public private(set) var rejectedWhileSyncing: [String] = []

    /// How many sessions one refresh will read per sankalpa. The service pages at 200; ten pages
    /// is far more practice than a single user accumulates, and it keeps a refresh bounded.
    static let maximumSessionPages = 10
    static let sessionPageSize = 200

    public init(
        location: ServiceLocation,
        clock: SankalpaClock,
        cache: PracticeCache = PracticeCache(),
        transport: APITransport = URLSessionTransport()
    ) {
        self.location = location
        self.clock = clock
        self.cache = cache
        self.transport = transport
        self.client = SankalpaAPIClient(baseURL: location.url, transport: transport)
        self.queries = SankalpaApplicationService(
            sankalpas: store, sessions: store, clock: clock
        )
        loadFromCache()
    }

    /// Points the app at a different computer. The cached practice belongs to the old one, so it
    /// goes; the outbox stays, because those sessions still have to reach a service somewhere and
    /// dropping them would lose the only copy.
    public func relocate(to location: ServiceLocation) async {
        guard location != self.location else { return }
        self.location = location
        self.client = SankalpaAPIClient(baseURL: location.url, transport: transport)
        store.replace(sankalpas: [], sessions: [], counts: [:])
        hasLoaded = false
        isShowingCachedPractice = false
        refreshFailure = nil
        loadFromCache()
        await sync()
    }

    public var serviceLocation: ServiceLocation { location }

    public func now() -> CalendarMoment { clock.now() }
    public func today() -> CalendarDay { clock.today() }

    /// Reads whatever the phone already holds, so the first frame has something in it whether or
    /// not the service answers. The cache is discarded silently when it cannot be used; the outbox
    /// reports for itself, because it is the copy of record until the service takes it.
    private func loadFromCache() {
        pending = cache.loadOutbox()
        store.replacePending(pending)
        if let cached = cache.loadCache(for: location) {
            store.replace(
                sankalpas: cached.sankalpas,
                sessions: cached.sessions,
                counts: Dictionary(
                    uniqueKeysWithValues: cached.counts.compactMap { key, value in
                        UUID(uuidString: key).map { (SankalpaId($0), value) }
                    }
                )
            )
            hasLoaded = true
            isShowingCachedPractice = true
        } else if !pending.isEmpty {
            // Sessions are waiting but there is no practice to show them against. There is still
            // nothing to render, so this is not "loaded" — but they must not be lost either.
            hasLoaded = false
        }
        if let problem = cache.outboxProblem {
            refreshFailure = problem
            cache.clearOutboxProblem()
        }
    }

    // MARK: - Reading

    /// Reloads everything: the declarations, then each one's lifecycle audit and session history.
    ///
    /// It is `1 + 2N` requests because the list endpoint returns declarations only — no current
    /// period, no session count, no transitions — and the derived reads need all three. For a
    /// single user's handful of sankalpas that is the honest cost of keeping the screens' derived
    /// data without a projection the service does not offer.
    public func refresh() async {
        do {
            let listed = try await client.list()
            let loaded = try await withThrowingTaskGroup(of: LoadedSankalpa.self) { group in
                for dto in listed {
                    group.addTask { [client] in
                        let id = SankalpaId(dto.id)
                        async let history = client.lifecycleHistory(id)
                        let sessions = try await Self.allSessions(for: id, using: client)
                        return LoadedSankalpa(
                            dto: dto,
                            transitions: try await history,
                            sessions: sessions.items,
                            totalSessions: sessions.total
                        )
                    }
                }
                var results: [SankalpaId: LoadedSankalpa] = [:]
                for try await loaded in group {
                    results[SankalpaId(loaded.dto.id)] = loaded
                }
                // The task group finishes in whatever order the requests do; the service's own
                // ordering (newest declaration first) is what the list screen expects to start from.
                return listed.compactMap { results[SankalpaId($0.id)] }
            }

            var sankalpas: [Sankalpa] = []
            var sessions: [Session] = []
            var counts: [SankalpaId: Int] = [:]
            for item in loaded {
                let sankalpa = try APIMapping.sankalpa(item.dto, transitions: item.transitions)
                sankalpas.append(sankalpa)
                sessions.append(contentsOf: try item.sessions.map(APIMapping.session))
                counts[sankalpa.id] = item.totalSessions
            }

            // Rule 2: what the service says replaces what the phone thought, outright.
            store.replace(sankalpas: sankalpas, sessions: sessions, counts: counts)
            hasLoaded = true
            isShowingCachedPractice = false
            refreshFailure = nil
            cache.saveCache(CachedPractice(
                serviceLocation: location.displayText,
                sankalpas: sankalpas,
                sessions: sessions,
                counts: Dictionary(
                    uniqueKeysWithValues: counts.map { ($0.key.value.uuidString, $0.value) }
                )
            ))
            // A pending session the service has since accepted — because the request arrived and
            // only the answer was lost — is already in what came back. Dropping it here is what
            // stops a flaky connection turning one session into two.
            dropPendingAlreadyOnTheServer(sessions)
        } catch let failure as APIFailure {
            refreshFailure = failure.fallbackMessage
        } catch let failure as WireDecodingError {
            refreshFailure = failure.message
        } catch {
            refreshFailure = "Your practice could not be reached right now. Try again."
        }
    }

    /// Sends whatever is waiting, then re-reads. This is the operation the app actually wants
    /// nearly everywhere: on launch, on coming back to the foreground, and on pull-to-refresh.
    ///
    /// The outbox is flushed first so the refresh that follows already contains those sessions,
    /// which is what makes them stop being pending rather than briefly appearing twice.
    public func sync() async {
        await flushOutbox()
        await refresh()
    }

    /// Offers each waiting session to the service, oldest first.
    ///
    /// A refusal is the service applying a rule — the sankalpa was stopped while the phone was
    /// away, say — so the session is dropped and reported rather than retried forever. Rule 2:
    /// the service wins, even about something the phone already showed as logged. Anything that
    /// simply could not be delivered stays for next time, and stops the flush: there is no point
    /// offering the rest to a service that is not answering.
    private func flushOutbox() async {
        guard !pending.isEmpty else { return }
        var remaining: [PendingSession] = []
        var rejected: [String] = []
        var stopped = false

        for entry in pending {
            if stopped {
                remaining.append(entry)
                continue
            }
            do {
                _ = try await client.logSession(entry.sankalpaId, occurredAt: entry.occurredAt)
            } catch let failure as APIFailure {
                switch failure {
                case .refused:
                    rejected.append(describe(entry, refusedBy: failure))
                case .unreachable:
                    remaining.append(entry)
                    stopped = true
                }
            } catch {
                remaining.append(entry)
                stopped = true
            }
        }

        rejectedWhileSyncing += rejected
        savePending(remaining)
    }

    /// What to tell someone about a session they logged that the service then would not take.
    ///
    /// The reason comes from the service, not from this phone's copy. Everywhere else the app
    /// rebuilds a refusal in its own words using what it holds — but here what it holds is exactly
    /// what turned out to be wrong, because being out of date is why the session was refused.
    /// Explaining it from the stale copy produces sentences that contradict themselves: that the
    /// sankalpa was In progress at the very moment the service is refusing the session for it not
    /// having been.
    private func describe(_ entry: PendingSession, refusedBy failure: APIFailure) -> String {
        let title = store.find(entry.sankalpaId)?.title.value ?? "a sankalpa"
        let when = "\(entry.occurredAt.day.longDisplayText) at \(AppTime.timeText(entry.occurredAt))"
        var reason = failure.fallbackMessage
        if !reason.hasSuffix(".") { reason += "." }
        return "The session for \(title) on \(when) could not be kept. \(reason)"
    }

    private func dropPendingAlreadyOnTheServer(_ serverSessions: [Session]) {
        guard !pending.isEmpty else { return }
        let onServer = Set(serverSessions.map { SessionKey($0.sankalpaId, $0.occurredAt) })
        let remaining = pending.filter { !onServer.contains(SessionKey($0.sankalpaId, $0.occurredAt)) }
        if remaining.count != pending.count { savePending(remaining) }
    }

    /// A session's identity as far as delivery is concerned. The service assigns its own id, so
    /// the phone cannot match on that — what it can match on is the sankalpa and the moment, which
    /// is what the user actually chose.
    private struct SessionKey: Hashable {
        let sankalpaId: SankalpaId
        let occurredAt: CalendarMoment
        init(_ sankalpaId: SankalpaId, _ occurredAt: CalendarMoment) {
            self.sankalpaId = sankalpaId
            self.occurredAt = occurredAt
        }
    }

    private func savePending(_ entries: [PendingSession]) {
        pending = entries
        store.replacePending(entries)
        cache.saveOutbox(entries)
    }

    /// Reads the refusals collected during a sync and forgets them, so the same news is not shown
    /// twice.
    public func takeSyncRejections() -> [String] {
        let rejections = rejectedWhileSyncing
        rejectedWhileSyncing = []
        return rejections
    }

    private struct LoadedSankalpa: Sendable {
        let dto: API.SankalpaResponse
        let transitions: [API.LifecycleTransitionResponse]
        let sessions: [API.SessionResponse]
        let totalSessions: Int
    }

    /// Reads session history a page at a time. `totalElements` from the first page is kept as the
    /// lifetime count even when the pages are capped, so a summary never reports fewer sessions
    /// than the service holds.
    private static func allSessions(
        for id: SankalpaId, using client: SankalpaAPIClient
    ) async throws -> (items: [API.SessionResponse], total: Int) {
        var items: [API.SessionResponse] = []
        var total = 0
        for page in 0..<maximumSessionPages {
            let response = try await client.sessionPage(id, page: page, size: sessionPageSize)
            if page == 0 { total = response.totalElements }
            items.append(contentsOf: response.content)
            if items.count >= response.totalElements || response.content.isEmpty { break }
        }
        return (items, total)
    }

    // MARK: - Commands

    public func declare(_ declaration: Declaration) async -> SankalpaCommandError? {
        do {
            _ = try await client.declare(declaration)
        } catch {
            return refusal(error, context: Context(declaration: declaration))
        }
        // The command got through, so the service is reachable: anything waiting goes now.
        await sync()
        return nil
    }

    public func begin(
        _ id: SankalpaId, effectiveAt: CalendarMoment? = nil
    ) async -> SankalpaCommandError? {
        await lifecycle(id, target: .inProgress) { try await self.client.begin(id, effectiveAt: effectiveAt) }
    }

    public func pause(_ id: SankalpaId) async -> SankalpaCommandError? {
        await lifecycle(id, target: .paused) { try await self.client.pause(id) }
    }

    public func resume(_ id: SankalpaId) async -> SankalpaCommandError? {
        await lifecycle(id, target: .inProgress) { try await self.client.resume(id) }
    }

    public func complete(
        _ id: SankalpaId, outcome: CompletionOutcome
    ) async -> SankalpaCommandError? {
        await lifecycle(id, target: outcome.state) { try await self.client.complete(id, outcome: outcome) }
    }

    public func stop(_ id: SankalpaId) async -> SankalpaCommandError? {
        await lifecycle(id, target: .stopped) { try await self.client.stop(id) }
    }

    /// Records a performed session, whether or not the service can be reached.
    ///
    /// The service is asked first and its answer is final. Only when the request cannot be
    /// delivered at all does the phone fall back to deciding for itself — and it decides with the
    /// same rules, because the aggregate it cached knows the commitment and the lifecycle. A
    /// session the domain would refuse is refused here too, so going offline never becomes a way
    /// to record something that is not allowed; it only defers *who* says so.
    ///
    /// The session is reported as logged only once it is on disk. Saying "logged" over something
    /// held in memory would lose it on the next launch, which is the one thing the outbox exists
    /// to prevent.
    public func logSession(
        _ id: SankalpaId, occurredAt: CalendarMoment
    ) async -> SankalpaCommandError? {
        do {
            _ = try await client.logSession(id, occurredAt: occurredAt)
        } catch let failure as APIFailure {
            guard case .unreachable = failure else {
                return refusal(failure, context: Context(id: id, occurredAt: occurredAt))
            }
            return logSessionWhileOffline(id, occurredAt: occurredAt, unreachable: failure)
        } catch {
            return refusal(error, context: Context(id: id, occurredAt: occurredAt))
        }
        await sync()
        return nil
    }

    private func logSessionWhileOffline(
        _ id: SankalpaId,
        occurredAt: CalendarMoment,
        unreachable: APIFailure
    ) -> SankalpaCommandError? {
        guard let sankalpa = store.find(id) else {
            // Nothing cached to check against, so there is no honest way to accept it.
            return .storage(.unavailable(unreachable.fallbackMessage))
        }
        do {
            _ = try sankalpa.logSession(occurredAt: occurredAt, now: clock.now())
        } catch {
            return .session(error)
        }

        let entry = PendingSession(
            sankalpaId: id, occurredAt: occurredAt, loggedAt: clock.now()
        )
        guard cache.saveOutbox(pending + [entry]) else {
            return .storage(.writeFailed)
        }
        savePending(pending + [entry])
        return nil
    }

    private func lifecycle(
        _ id: SankalpaId,
        target: LifecycleState,
        _ command: @escaping () async throws -> API.SankalpaResponse
    ) async -> SankalpaCommandError? {
        do {
            _ = try await command()
        } catch {
            return refusal(error, context: Context(id: id, target: target))
        }
        await sync()
        return nil
    }

    // MARK: - Refusals

    private struct Context {
        var id: SankalpaId?
        var target: LifecycleState?
        var occurredAt: CalendarMoment?
        var declaration: Declaration?
    }

    private func refusal(_ error: Error, context: Context) -> SankalpaCommandError {
        guard let failure = error as? APIFailure else {
            return .storage(.unavailable("Your practice could not be reached right now. Try again."))
        }
        return ServerRefusal.commandError(
            for: failure,
            context: ServerRefusal.Context(
                sankalpa: context.id.flatMap(store.find),
                today: clock.today(),
                target: context.target,
                occurredAt: context.occurredAt,
                declaration: context.declaration
            )
        )
    }
}
