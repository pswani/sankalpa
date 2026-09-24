import Foundation
import SankalpaCore

final class SnapshotStore: SankalpaRepository, SessionRepository {
    private var sankalpas: [Sankalpa] = []
    private var serverSessions: [Session] = []
    private var pendingCreates: [Session] = []
    private var pendingDeletionIds: Set<SessionId> = []

    func replace(sankalpas: [Sankalpa], sessions: [Session]) {
        self.sankalpas = sankalpas
        serverSessions = Self.unique(sessions)
    }

    func replaceOperations(creates: [PendingSession], deletions: [PendingSessionDeletion]) {
        pendingCreates = creates.map(\.session)
        pendingDeletionIds = Set(deletions.map(\.id))
    }

    func accept(_ session: Session) {
        serverSessions.removeAll { $0.id == session.id }
        serverSessions.append(session)
    }

    func acceptDeletion(_ id: SessionId) {
        serverSessions.removeAll { $0.id == id }
    }

    func snapshot() -> (sankalpas: [Sankalpa], sessions: [Session]) {
        (sankalpas, serverSessions)
    }

    private var sessions: [Session] {
        let deleted = pendingDeletionIds
        return Self.unique(serverSessions + pendingCreates).filter { !deleted.contains($0.id) }
    }

    private static func unique(_ sessions: [Session]) -> [Session] {
        var seen: Set<SessionId> = []
        return sessions.filter { seen.insert($0.id).inserted }
    }

    func all() -> [Sankalpa] { sankalpas }
    func find(_ id: SankalpaId) -> Sankalpa? { sankalpas.first { $0.id == id } }
    func save(_ sankalpa: Sankalpa) throws(PersistenceError) { throw .unavailable(Self.readOnly) }
    func save(_ session: Session) throws(PersistenceError) { throw .unavailable(Self.readOnly) }
    @discardableResult
    func delete(_ sessionId: SessionId) throws(PersistenceError) -> Bool {
        throw .unavailable(Self.readOnly)
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
        sessions.count { $0.sankalpaId == sankalpaId }
    }
    func allSessions(for sankalpaId: SankalpaId) -> [Session] {
        sessions.filter { $0.sankalpaId == sankalpaId }
    }
    private static let readOnly = "Changes are saved by the Sankalpa service, not on this device."
}

public struct SessionReceipt: Hashable, Sendable {
    public enum Status: Hashable, Sendable { case accepted, pending }
    public let session: Session
    public let status: Status
}

public enum SessionLogDisposition: Sendable {
    case accepted(SessionReceipt)
    case pending(SessionReceipt)
    case rejected(SankalpaCommandError)
}

public enum SessionDeleteDisposition: Sendable {
    case accepted
    case pending
    case rejected(SankalpaCommandError)
}

/// Service-backed practice with a durable operation overlay. Session creates and deletes are
/// journaled before network I/O, use one stable id, and remain visible (or suppressed) until the
/// originating service reaches a conclusive result.
@MainActor
public final class RemoteSankalpaService {
    private var client: SankalpaAPIClient
    private let transport: APITransport
    private let store = SnapshotStore()
    private let clock: SankalpaClock
    private let cache: PracticeCache
    private var location: ServiceLocation
    private var journal: ReliabilityJournal
    private var bindingRevision = UUID()
    /// Identifies the newest refresh that may publish a server snapshot. Accepted local mutations
    /// also rotate it so a read started before that mutation cannot overwrite the newer fact.
    private var refreshPublicationRevision = UUID()

    public let queries: SankalpaApplicationService
    public private(set) var refreshFailure: String?
    public private(set) var hasLoaded = false
    public private(set) var isShowingCachedPractice = false
    public private(set) var pending: [PendingSession] = []
    public private(set) var pendingDeletions: [PendingSessionDeletion] = []

    static let sessionPageSize = 200

    public init(
        location: ServiceLocation, clock: SankalpaClock,
        cache: PracticeCache = PracticeCache(), transport: APITransport = URLSessionTransport()
    ) {
        self.location = location
        self.clock = clock
        self.cache = cache
        self.transport = transport
        client = SankalpaAPIClient(baseURL: location.url, transport: transport)
        journal = cache.loadJournal(for: location)
        queries = SankalpaApplicationService(sankalpas: store, sessions: store, clock: clock)
        loadFromCache()
    }

    public var serviceLocation: ServiceLocation { location }
    public var pendingChangeCount: Int { pending.count + pendingDeletions.count }
    public var reliabilityProblem: String? { cache.outboxProblem }
    public var quarantinedCreateIds: Set<SessionId> { Set(journal.quarantinedCreates) }
    public func now() -> CalendarMoment { clock.now() }
    public func today() -> CalendarDay { clock.today() }
    /// The complete locally known history, including pending creates and excluding pending
    /// deletions. The service refresh itself is fully paginated, so this is not range-truncated.
    public func allSessions(for id: SankalpaId) -> [Session] {
        store.allSessions(for: id)
    }

    /// Pending commands stay bound to their service instance. Address changes are refused while
    /// any exist rather than silently retargeting them to a different database.
    @discardableResult
    public func relocate(to location: ServiceLocation) async -> Bool {
        guard location != self.location else { return true }
        guard pendingChangeCount == 0 else {
            refreshFailure = "Send or resolve pending session changes before changing services."
            return false
        }
        bindingRevision = UUID()
        refreshPublicationRevision = UUID()
        self.location = location
        client = SankalpaAPIClient(baseURL: location.url, transport: transport)
        journal = cache.loadJournal(for: location)
        store.replace(sankalpas: [], sessions: [])
        applyOperations()
        hasLoaded = false
        isShowingCachedPractice = false
        refreshFailure = nil
        loadFromCache()
        await sync()
        return true
    }

    private func loadFromCache() {
        applyOperations()
        if let cached = cache.loadCache(for: location) {
            store.replace(sankalpas: cached.sankalpas, sessions: cached.sessions)
            applyOperations()
            hasLoaded = true
            isShowingCachedPractice = true
        }
        if let problem = cache.outboxProblem { refreshFailure = problem }
    }

    private func applyOperations() {
        pending = journal.creates
        pendingDeletions = journal.deletions
        let activeInstance = journal.capability?.serviceInstanceId
        store.replaceOperations(
            creates: pending.filter { $0.serviceInstanceId == activeInstance },
            deletions: pendingDeletions.filter { $0.serviceInstanceId == activeInstance }
        )
    }

    @discardableResult
    private func persistJournal(_ proposed: ReliabilityJournal) -> Bool {
        guard cache.saveJournal(proposed) else { return false }
        journal = proposed
        applyOperations()
        return true
    }

    private func persistSnapshot() -> Bool {
        let snapshot = store.snapshot()
        return cache.saveCache(CachedPractice(
            serviceLocation: location.displayText,
            sankalpas: snapshot.sankalpas,
            sessions: snapshot.sessions
        ))
    }

    // MARK: - Capability, refresh, and reconciliation

    private func discoverCapability() async throws -> ServiceCapability {
        let response: API.CapabilitiesResponse
        do {
            response = try await client.capabilities()
        } catch let failure as APIFailure {
            if case .unreachable = failure,
               journal.serviceLocation == location.displayText,
               let cached = journal.capability,
               cached.supportsReliableSessions {
                return cached
            }
            throw failure
        }
        let capability = ServiceCapability(
            sessionCommandIdentity: response.sessionCommandIdentity,
            serviceInstanceId: response.serviceInstanceId
        )
        guard capability.supportsReliableSessions else {
            // Without pending work, a reachable downgrade revokes offline mutation authority.
            // With pending work, preserve the old binding so the operations remain recoverable
            // against their origin, but still send nothing to the incompatible service.
            if journal.creates.isEmpty && journal.deletions.isEmpty {
                var proposed = journal
                proposed.capability = nil
                _ = persistJournal(proposed)
            }
            throw APIFailure.unreachable(
                "Update the Sankalpa service before logging or deleting sessions."
            )
        }
        let hasPendingOperations = !journal.creates.isEmpty || !journal.deletions.isEmpty
        if hasPendingOperations, let bound = journal.capability?.serviceInstanceId,
           bound != capability.serviceInstanceId {
            throw APIFailure.unreachable(
                "Pending session changes belong to a different Sankalpa service and were not sent."
            )
        }
        var proposed = journal
        proposed.serviceLocation = location.displayText
        proposed.capability = capability
        // Capability persistence authorizes later offline use, but a disk problem must not make
        // otherwise readable server data disappear. A mutation still has to persist its complete
        // operation and will correctly fail if the journal remains unwritable.
        if !persistJournal(proposed) { journal = proposed }
        return capability
    }

    public func refresh() async {
        let binding = bindingRevision
        let publication = UUID()
        refreshPublicationRevision = publication
        let refreshClient = client
        do {
            _ = try await discoverCapability()
            let listed = try await refreshClient.list()
            let loaded = try await withThrowingTaskGroup(of: LoadedSankalpa.self) { group in
                for dto in listed {
                    group.addTask {
                        let id = SankalpaId(dto.id)
                        async let history = refreshClient.lifecycleHistory(id)
                        let sessions = try await Self.allSessions(for: id, using: refreshClient)
                        return LoadedSankalpa(dto: dto, transitions: try await history, sessions: sessions)
                    }
                }
                var results: [SankalpaId: LoadedSankalpa] = [:]
                for try await value in group { results[SankalpaId(value.dto.id)] = value }
                return listed.compactMap { results[SankalpaId($0.id)] }
            }
            var sankalpas: [Sankalpa] = []
            var sessions: [Session] = []
            for item in loaded {
                sankalpas.append(try APIMapping.sankalpa(item.dto, transitions: item.transitions))
                sessions.append(contentsOf: try item.sessions.map(APIMapping.session))
            }
            guard Set(sessions.map(\.id)).count == sessions.count else {
                throw APIFailure.unreachable("The service returned duplicate session identities.")
            }
            guard binding == bindingRevision,
                  publication == refreshPublicationRevision
            else { return }
            store.replace(sankalpas: sankalpas, sessions: sessions)
            applyOperations()
            hasLoaded = true
            isShowingCachedPractice = false
            refreshFailure = nil
            _ = persistSnapshot()
        } catch let failure as APIFailure {
            refreshFailure = failure.fallbackMessage
        } catch let failure as WireDecodingError {
            refreshFailure = failure.message
        } catch {
            refreshFailure = "Your practice could not be reached right now. Try again."
        }
    }

    public func sync() async {
        do {
            let capability = try await discoverCapability()
            await flushOperations(capability: capability)
        } catch {
            // Refresh reports the connection/capability problem and preserves all operations.
        }
        await refresh()
    }

    private func flushOperations(capability: ServiceCapability) async {
        for deletion in journal.deletions {
            guard deletion.serviceInstanceId == capability.serviceInstanceId else {
                recordNotice("A pending deletion belongs to a different Sankalpa service and was not sent.")
                continue
            }
            do {
                try await client.deleteSession(
                    deletion.sankalpaId, sessionId: deletion.id,
                    serviceInstanceId: deletion.serviceInstanceId
                )
                _ = completeDeletion(deletion)
            } catch let failure as APIFailure {
                if isServiceMismatch(failure) {
                    recordNotice("A pending deletion belongs to a different Sankalpa service and was not sent.")
                    return
                } else if isDefinitiveRejection(failure) {
                    guard rejectDeletion(deletion, failure: failure) else { return }
                }
                else { return }
            } catch { return }
        }
        for create in journal.creates {
            if journal.quarantinedCreates.contains(create.id) { continue }
            guard create.serviceInstanceId == capability.serviceInstanceId else {
                recordNotice("A pending session belongs to a different Sankalpa service and was not sent.")
                continue
            }
            do {
                let response = try await client.logSession(
                    create.sankalpaId, sessionId: create.id, occurredAt: create.occurredAt,
                    serviceInstanceId: capability.serviceInstanceId
                )
                _ = try completeCreate(create, response: response)
            } catch is SessionProtocolViolation {
                _ = quarantine(create)
                return
            } catch let failure as APIFailure {
                if isServiceMismatch(failure) {
                    recordNotice("A pending session belongs to a different Sankalpa service and was not sent.")
                    return
                } else if isDefinitiveRejection(failure) {
                    guard rejectCreate(create, failure: failure) else { return }
                }
                else { return }
            } catch { return }
        }
    }

    private struct LoadedSankalpa: Sendable {
        let dto: API.SankalpaResponse
        let transitions: [API.LifecycleTransitionResponse]
        let sessions: [API.SessionResponse]
    }

    private static func allSessions(
        for id: SankalpaId, using client: SankalpaAPIClient
    ) async throws -> [API.SessionResponse] {
        do {
            return try await allSessionsAttempt(for: id, using: client)
        } catch is InconsistentSessionPages {
            return try await allSessionsAttempt(for: id, using: client)
        }
    }

    private struct InconsistentSessionPages: Error {}

    private static func allSessionsAttempt(
        for id: SankalpaId, using client: SankalpaAPIClient
    ) async throws -> [API.SessionResponse] {
        var items: [API.SessionResponse] = []
        var expectedTotal: Int?
        var expectedPages: Int?
        var page = 0
        while true {
            let response = try await client.sessionPage(id, page: page, size: sessionPageSize)
            guard response.page == page, response.size > 0, response.totalElements >= 0,
                  response.totalPages >= 0,
                  expectedTotal == nil || expectedTotal == response.totalElements,
                  expectedPages == nil || expectedPages == response.totalPages
            else { throw InconsistentSessionPages() }
            expectedTotal = response.totalElements
            expectedPages = response.totalPages
            items.append(contentsOf: response.content)
            page += 1
            if page >= response.totalPages { break }
            guard !response.content.isEmpty else {
                throw InconsistentSessionPages()
            }
        }
        guard items.count == expectedTotal,
              Set(items.map(\.id)).count == items.count
        else { throw InconsistentSessionPages() }
        return items
    }

    // MARK: - Session commands

    public func logSessionCommand(
        _ id: SankalpaId, occurredAt: CalendarMoment
    ) async -> SessionLogDisposition {
        guard cache.outboxProblem == nil else {
            return .rejected(.storage(.unavailable(cache.outboxProblem!)))
        }
        guard let sankalpa = store.find(id) else {
            return .rejected(.storage(.unavailable("Refresh the practice before logging a session.")))
        }
        do { _ = try sankalpa.logSession(occurredAt: occurredAt, now: clock.now()) }
        catch { return .rejected(.session(error)) }

        let capability: ServiceCapability
        do { capability = try await discoverCapability() }
        catch { return .rejected(refusal(error, context: Context(id: id, occurredAt: occurredAt))) }

        let entry = PendingSession(
            sankalpaId: id, occurredAt: occurredAt, loggedAt: clock.now(),
            serviceInstanceId: capability.serviceInstanceId
        )
        var proposed = journal
        proposed.creates.append(entry)
        proposed.recentLogs.append(RecentSessionLog(
            sessionId: entry.id, sankalpaId: id, acceptedAt: clock.now()
        ))
        proposed.recentLogs = Array(proposed.recentLogs.suffix(64))
        guard persistJournal(proposed) else { return .rejected(.storage(.writeFailed)) }

        do {
            let response = try await client.logSession(
                id, sessionId: entry.id, occurredAt: occurredAt,
                serviceInstanceId: capability.serviceInstanceId
            )
            let session = try completeCreate(entry, response: response)
            return .accepted(SessionReceipt(session: session, status: .accepted))
        } catch is SessionProtocolViolation {
            _ = quarantine(entry)
            return .pending(SessionReceipt(session: entry.session, status: .pending))
        } catch let failure as APIFailure {
            if isServiceMismatch(failure) {
                recordNotice("This session is still pending because the service at this address has changed.")
                return .pending(SessionReceipt(session: entry.session, status: .pending))
            } else if isDefinitiveRejection(failure) {
                guard rejectCreate(entry, failure: failure) else {
                    return .pending(SessionReceipt(session: entry.session, status: .pending))
                }
                return .rejected(
                    refusal(failure, context: Context(id: id, occurredAt: occurredAt))
                )
            }
            renewRecentGuard(entry.id)
            return .pending(SessionReceipt(session: entry.session, status: .pending))
        } catch {
            renewRecentGuard(entry.id)
            return .pending(SessionReceipt(session: entry.session, status: .pending))
        }
    }

    public func logSession(
        _ id: SankalpaId, occurredAt: CalendarMoment
    ) async -> SankalpaCommandError? {
        switch await logSessionCommand(id, occurredAt: occurredAt) {
        case .accepted, .pending: return nil
        case .rejected(let error): return error
        }
    }

    public func deleteSession(
        _ session: Session
    ) async -> SessionDeleteDisposition {
        guard cache.outboxProblem == nil else {
            return .rejected(.storage(.unavailable(cache.outboxProblem!)))
        }
        let capability: ServiceCapability
        do { capability = try await discoverCapability() }
        catch { return .rejected(refusal(error, context: Context(id: session.sankalpaId))) }

        let deletion = PendingSessionDeletion(
            id: session.id, sankalpaId: session.sankalpaId,
            occurredAt: session.occurredAt,
            serviceInstanceId: capability.serviceInstanceId, requestedAt: clock.now()
        )
        var proposed = journal
        proposed.creates.removeAll { $0.id == session.id }
        proposed.quarantinedCreates.removeAll { $0 == session.id }
        proposed.deletions.removeAll { $0.id == session.id }
        proposed.deletions.append(deletion)
        guard persistJournal(proposed) else { return .rejected(.storage(.writeFailed)) }

        do {
            try await client.deleteSession(
                session.sankalpaId, sessionId: session.id,
                serviceInstanceId: capability.serviceInstanceId
            )
            return completeDeletion(deletion) ? .accepted : .pending
        } catch let failure as APIFailure {
            if isServiceMismatch(failure) {
                recordNotice("This deletion is still pending because the service at this address has changed.")
                return .pending
            } else if isDefinitiveRejection(failure) {
                guard rejectDeletion(deletion, failure: failure) else { return .pending }
                return .rejected(refusal(failure, context: Context(id: session.sankalpaId)))
            }
            return .pending
        } catch { return .pending }
    }

    public func shouldConfirmRepeat(for id: SankalpaId) -> Bool {
        let suppressed = Set(journal.deletions.map(\.id))
        guard let last = journal.recentLogs.last(where: {
            $0.sankalpaId == id && !suppressed.contains($0.sessionId)
        }) else { return false }
        let seconds = last.acceptedAt.day.days(until: clock.now().day) * CalendarMoment.secondsPerDay
            + clock.now().secondOfDay - last.acceptedAt.secondOfDay
        return (0..<60).contains(seconds)
    }

    private func completeCreate(
        _ entry: PendingSession, response: API.SessionResponse
    ) throws -> Session {
        guard response.id == entry.id.value,
              response.sankalpaId == entry.sankalpaId.value,
              WireFormat.moment(from: response.occurredAt) == entry.occurredAt
        else { throw SessionProtocolViolation() }
        let session = try APIMapping.session(response)
        // Undo may have replaced this exact create while the request was in flight. In that case
        // do not let the older response remove or visually resurrect the newer delete operation.
        guard journal.creates.contains(where: { $0.id == entry.id && $0.revision == entry.revision })
        else { return session }
        refreshPublicationRevision = UUID()
        store.accept(session)
        guard persistSnapshot() else { throw PersistenceError.writeFailed }
        var proposed = journal
        proposed.creates.removeAll { $0.id == entry.id && $0.revision == entry.revision }
        proposed.quarantinedCreates.removeAll { $0 == entry.id }
        if let index = proposed.recentLogs.lastIndex(where: { $0.sessionId == entry.id }) {
            proposed.recentLogs[index] = RecentSessionLog(
                sessionId: entry.id, sankalpaId: entry.sankalpaId, acceptedAt: clock.now()
            )
        }
        guard persistJournal(proposed) else { throw PersistenceError.writeFailed }
        return session
    }

    @discardableResult
    private func completeDeletion(_ entry: PendingSessionDeletion) -> Bool {
        guard journal.deletions.contains(where: { $0.id == entry.id && $0.revision == entry.revision })
        else { return true }
        refreshPublicationRevision = UUID()
        store.acceptDeletion(entry.id)
        guard persistSnapshot() else { return false }
        var proposed = journal
        proposed.deletions.removeAll { $0.id == entry.id && $0.revision == entry.revision }
        proposed.recentLogs.removeAll { $0.sessionId == entry.id }
        return persistJournal(proposed)
    }

    @discardableResult
    private func rejectCreate(_ entry: PendingSession, failure: APIFailure) -> Bool {
        guard journal.creates.contains(where: { $0.id == entry.id && $0.revision == entry.revision })
        else { return false }
        var proposed = journal
        proposed.creates.removeAll { $0.id == entry.id && $0.revision == entry.revision }
        proposed.quarantinedCreates.removeAll { $0 == entry.id }
        proposed.recentLogs.removeAll { $0.sessionId == entry.id }
        proposed.notices.append(describe(entry, refusedBy: failure))
        return persistJournal(proposed)
    }

    @discardableResult
    private func rejectDeletion(_ entry: PendingSessionDeletion, failure: APIFailure) -> Bool {
        guard journal.deletions.contains(where: { $0.id == entry.id && $0.revision == entry.revision })
        else { return false }
        var proposed = journal
        proposed.deletions.removeAll { $0.id == entry.id && $0.revision == entry.revision }
        proposed.notices.append("The session could not be deleted. \(failure.fallbackMessage)")
        return persistJournal(proposed)
    }

    private func recordNotice(_ text: String) {
        var proposed = journal
        if !proposed.notices.contains(text) { proposed.notices.append(text) }
        _ = persistJournal(proposed)
    }

    private struct SessionProtocolViolation: Error {}

    @discardableResult
    private func quarantine(_ entry: PendingSession) -> Bool {
        guard journal.creates.contains(where: {
            $0.id == entry.id && $0.revision == entry.revision
        }) else { return false }
        var proposed = journal
        if !proposed.quarantinedCreates.contains(entry.id) {
            proposed.quarantinedCreates.append(entry.id)
        }
        let message = "A service response did not match pending session \(entry.id.value.uuidString). It was preserved and automatic retries stopped."
        if !proposed.notices.contains(message) { proposed.notices.append(message) }
        return persistJournal(proposed)
    }

    private func renewRecentGuard(_ sessionId: SessionId) {
        guard let index = journal.recentLogs.lastIndex(where: { $0.sessionId == sessionId })
        else { return }
        var proposed = journal
        let old = proposed.recentLogs[index]
        proposed.recentLogs[index] = RecentSessionLog(
            sessionId: old.sessionId, sankalpaId: old.sankalpaId, acceptedAt: clock.now()
        )
        _ = persistJournal(proposed)
    }

    private func describe(_ entry: PendingSession, refusedBy failure: APIFailure) -> String {
        let title = store.find(entry.sankalpaId)?.title.value ?? "a sankalpa"
        var reason = failure.fallbackMessage
        if !reason.hasSuffix(".") { reason += "." }
        return "The session for \(title) could not be kept. \(reason)"
    }

    public var reconciliationNotices: [String] { journal.notices }

    public func acknowledgeReconciliationNotices() {
        var proposed = journal
        proposed.notices = []
        _ = persistJournal(proposed)
    }

    private func isServiceMismatch(_ failure: APIFailure) -> Bool {
        if case .refused(let code, _, _) = failure { return code == "SERVICE_INSTANCE_MISMATCH" }
        return false
    }

    private func isDefinitiveRejection(_ failure: APIFailure) -> Bool {
        guard case .refused(let code, _, let status) = failure else { return false }
        if status == 408 || status == 429 || status >= 500 { return false }
        if status == 409 { return code == "SESSION_IDENTITY_CONFLICT" }
        return [400, 404, 410, 422].contains(status)
    }

    /// Completes the explicit warned recovery path for an unreadable or legacy journal.
    @discardableResult
    public func discardUnrecoverableSessionChanges() -> Bool {
        guard let replacement = cache.discardUnrecoverableJournal(for: location) else {
            refreshFailure = "The preserved session changes could not be discarded. Try again."
            return false
        }
        journal = replacement
        applyOperations()
        refreshFailure = nil
        return true
    }

    // MARK: - Other commands

    public func declare(_ declaration: Declaration) async -> SankalpaCommandError? {
        do { _ = try await client.declare(declaration) }
        catch { return refusal(error, context: Context(declaration: declaration)) }
        await sync(); return nil
    }
    public func begin(_ id: SankalpaId, effectiveAt: CalendarMoment? = nil) async -> SankalpaCommandError? {
        await lifecycle(id, target: .inProgress) { try await self.client.begin(id, effectiveAt: effectiveAt) }
    }
    public func pause(_ id: SankalpaId) async -> SankalpaCommandError? {
        await lifecycle(id, target: .paused) { try await self.client.pause(id) }
    }
    public func resume(_ id: SankalpaId) async -> SankalpaCommandError? {
        await lifecycle(id, target: .inProgress) { try await self.client.resume(id) }
    }
    public func complete(_ id: SankalpaId, outcome: CompletionOutcome) async -> SankalpaCommandError? {
        await lifecycle(id, target: outcome.state) { try await self.client.complete(id, outcome: outcome) }
    }
    public func stop(_ id: SankalpaId) async -> SankalpaCommandError? {
        await lifecycle(id, target: .stopped) { try await self.client.stop(id) }
    }
    private func lifecycle(
        _ id: SankalpaId, target: LifecycleState,
        _ command: @escaping () async throws -> API.SankalpaResponse
    ) async -> SankalpaCommandError? {
        do { _ = try await command() }
        catch { return refusal(error, context: Context(id: id, target: target)) }
        await sync(); return nil
    }

    private struct Context {
        var id: SankalpaId?
        var target: LifecycleState?
        var occurredAt: CalendarMoment?
        var declaration: Declaration?
    }

    private func refusal(_ error: Error, context: Context) -> SankalpaCommandError {
        if let persistence = error as? PersistenceError { return .storage(persistence) }
        guard let failure = error as? APIFailure else {
            return .storage(.unavailable("Your practice could not be reached right now. Try again."))
        }
        return ServerRefusal.commandError(
            for: failure,
            context: ServerRefusal.Context(
                sankalpa: context.id.flatMap(store.find), today: clock.today(),
                target: context.target, occurredAt: context.occurredAt,
                declaration: context.declaration
            )
        )
    }
}
