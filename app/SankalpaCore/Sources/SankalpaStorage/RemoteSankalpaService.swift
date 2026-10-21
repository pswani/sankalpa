import Foundation
import os
import SankalpaCore

/// Diagnostics for synchronization with the service (Console.app, subsystem `com.sankalpa`).
/// Messages carry states and service reasons, never practice titles or descriptions.
private let syncLog = Logger(subsystem: "com.sankalpa", category: "sync")

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
    private func contributes(_ fact: Session, to id: SankalpaId) -> Bool {
        guard let target = find(id) else { return false }
        if !sankalpas.contains(where: { $0.seriesId == target.seriesId && $0.id != target.id }) { return fact.sankalpaId == id }
        return SessionContributions.contributes(fact, to: target, members: sankalpas)
    }
    func sessions(for sankalpaId: SankalpaId, from: CalendarDay, until: CalendarDay) -> [Session] {
        guard from <= until else { return [] }
        return sessions.filter {
            contributes($0, to: sankalpaId) && $0.occurredAt.day >= from && $0.occurredAt.day <= until
        }
    }
    func sessions(from: CalendarDay, until: CalendarDay) -> [Session] {
        guard from <= until else { return [] }
        return sessions.filter { $0.occurredAt.day >= from && $0.occurredAt.day <= until }
    }
    func totalCount(for sankalpaId: SankalpaId) -> Int {
        sessions.count { contributes($0, to: sankalpaId) }
    }
    func allSessions(for sankalpaId: SankalpaId) -> [Session] {
        sessions.filter { contributes($0, to: sankalpaId) }
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

public struct AssistantCapability: Equatable, Sendable {
    public let enabled: Bool
    public let profile: String
    public let authenticationRequired: Bool
    public var batchSessionsVersion: Int = 0
    public var beginCorrectionVersion: Int = 0
}

/// Service-backed practice with a durable operation overlay. Session creates and deletes are
/// journaled before network I/O, use one stable id, and remain visible (or suppressed) until the
/// originating service reaches a conclusive result.
@MainActor
public final class RemoteSankalpaService {
    private var client: SankalpaAPIClient
    private var bearerToken: String?
    private let transport: APITransport
    private let store = SnapshotStore()
    private let clock: SankalpaClock
    private let cache: PracticeCache
    private var location: ServiceLocation
    private var extensionAttempt: ExtensionAttempt?
    private var extensionDelivering = false
    private var cachedServiceInstanceId: UUID?
    private var serverPracticeRevision: String?
    private var completeBaseSnapshot = true
    private var journal: ReliabilityJournal
    private var bindingRevision = UUID()
    /// Identifies the newest refresh that may publish a server snapshot. Accepted local mutations
    /// also rotate it so a read started before that mutation cannot overwrite the newer fact.
    private var refreshPublicationRevision = UUID()

    public let queries: SankalpaApplicationService
    public private(set) var refreshFailure: String?
    public private(set) var hasLoaded = false
    public private(set) var isShowingCachedPractice = false
    public private(set) var isServiceReachable = false
    public private(set) var pending: [PendingSession] = []
    public private(set) var pendingDeletions: [PendingSessionDeletion] = []
    public private(set) var assistantCapability: AssistantCapability?

    static let sessionPageSize = 200

    public init(
        location: ServiceLocation, clock: SankalpaClock,
        cache: PracticeCache = PracticeCache(), transport: APITransport = URLSessionTransport(),
        bearerToken: String? = nil
    ) {
        self.location = location
        self.clock = clock
        self.cache = cache
        self.transport = transport
        self.bearerToken = bearerToken
        client = SankalpaAPIClient(baseURL: location.url, bearerToken: bearerToken, transport: transport)
        extensionAttempt = cache.loadExtensionAttempt()
        journal = cache.loadJournal(for: location)
        queries = SankalpaApplicationService(sankalpas: store, sessions: store, clock: clock)
        loadFromCache()
        if let capability = journal.capability, capability.supportsLinkedExtensions { client = client.linked(to: capability.serviceInstanceId) }
    }

    public var supportsLinkedExtensions: Bool { journal.capability?.supportsLinkedExtensions == true }
    public var serviceInstanceId: UUID? { journal.capability?.serviceInstanceId }
    public var extensionNotice: String? { cache.extensionProblem ?? extensionAttempt?.notice }
    public var canAcknowledgeExtensionNotice: Bool { extensionAttempt?.state == .resolvedNotice }
    public var canRetryExtension: Bool { extensionAttempt?.state == .unresolved || extensionAttempt?.state == .acceptedAwaitingCache }
    public var hasExtensionAttempt: Bool { extensionAttempt != nil || cache.extensionProblem != nil }
    public var hasUnresolvedExtension: Bool { extensionAttempt?.isUnresolved == true || cache.extensionProblem != nil }
    public var extensionSourceId: SankalpaId? { extensionAttempt?.sourceId }
    public func linkedSeries(_ id: SankalpaId) -> [Sankalpa] {
        guard let vow = store.find(id) else { return [] }
        return store.all().filter { $0.seriesId == vow.seriesId }
            .sorted { ($0.commitment.periodCount?.value ?? 0) < ($1.commitment.periodCount?.value ?? 0) }
    }
    public func contributors(_ fact: Session) -> [Sankalpa] { SessionContributions.contributors(fact, members: store.all()) }
    public func seriesId(for id: SankalpaId) -> SankalpaId? { store.find(id)?.seriesId }
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
        guard pendingChangeCount == 0, !hasUnresolvedExtension else {
            refreshFailure = "Send or resolve pending session changes and extensions before changing services."
            return false
        }
        bindingRevision = UUID()
        refreshPublicationRevision = UUID()
        self.location = location
        client = SankalpaAPIClient(baseURL: location.url, bearerToken: bearerToken, transport: transport)
        journal = cache.loadJournal(for: location)
        store.replace(sankalpas: [], sessions: [])
        applyOperations()
        hasLoaded = false
        isShowingCachedPractice = false
        isServiceReachable = false
        assistantCapability = nil
        refreshFailure = nil
        serverPracticeRevision = nil
        cachedServiceInstanceId = nil
        completeBaseSnapshot = true
        loadFromCache()
        await sync()
        return true
    }

    public func useBearerToken(_ token: String?) {
        bearerToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        client = SankalpaAPIClient(baseURL: location.url, bearerToken: bearerToken, transport: transport)
        if let capability = journal.capability, capability.supportsLinkedExtensions {
            client = client.linked(to: capability.serviceInstanceId)
        }
        isServiceReachable = false
        assistantCapability = nil
    }

    private func loadFromCache() {
        applyOperations()
        if let cached = cache.loadCache(for: location) {
            if cached.sankalpas.contains(where: { $0.extensionOf != nil }) {
                guard cached.serviceInstanceId != nil,
                      journal.capability == nil || cached.serviceInstanceId == journal.capability?.serviceInstanceId,
                      (try? PracticeValidation.validate(cached.sankalpas, sessions: cached.sessions)) != nil else {
                    refreshFailure = "The linked practice cache needs a complete refresh."; return
                }
            }
            cachedServiceInstanceId = cached.serviceInstanceId ?? journal.capability?.serviceInstanceId
            serverPracticeRevision = cached.practiceRevision
            completeBaseSnapshot = cached.completeSnapshot
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
            sessions: snapshot.sessions, serviceInstanceId: journal.capability?.serviceInstanceId,
            practiceRevision: serverPracticeRevision, completeSnapshot: completeBaseSnapshot
        ))
    }

    // MARK: - Capability, refresh, and reconciliation

    private func discoverCapability() async throws -> ServiceCapability {
        let binding = bindingRevision
        let response: API.CapabilitiesResponse
        do {
            response = try await client.capabilities()
        } catch let failure as APIFailure {
            if case .unreachable = failure,
               location.matchesStoredAddress(journal.serviceLocation),
               let cached = journal.capability,
               cached.supportsReliableSessions {
                if cached.supportsLinkedExtensions { client = client.linked(to: cached.serviceInstanceId) }
                return cached
            }
            throw failure
        }
        guard binding == bindingRevision else { throw APIFailure.unreachable("The service changed during capability discovery.") }
        if let assistant = response.assistant {
            assistantCapability = AssistantCapability(enabled: assistant.enabled,
                profile: assistant.aguiProfile,
                authenticationRequired: assistant.authenticationRequired,
                batchSessionsVersion: response.assistantBatchSessions ?? 0,
                beginCorrectionVersion: response.assistantBeginCorrection ?? 0)
        } else {
            assistantCapability = nil
        }
        let capability = ServiceCapability(
            sessionCommandIdentity: response.sessionCommandIdentity,
            serviceInstanceId: response.serviceInstanceId, linkedSankalpaExtensions: response.linkedSankalpaExtensions
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
        let hasPendingOperations = !journal.creates.isEmpty || !journal.deletions.isEmpty || hasUnresolvedExtension
        if let attempt = extensionAttempt, attempt.isUnresolved, attempt.serviceInstanceId != capability.serviceInstanceId {
            throw APIFailure.unreachable("The pending extension belongs to a different Sankalpa service.")
        }
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
        client = SankalpaAPIClient(baseURL: location.url, bearerToken: bearerToken, transport: transport)
        if capability.supportsLinkedExtensions { client = client.linked(to: capability.serviceInstanceId) }
        if !capability.supportsLinkedExtensions && store.all().contains(where: { $0.extensionOf != nil }) {
            throw APIFailure.unreachable("Update the service before changing this linked practice.")
        }
        return capability
    }

    public func refresh() async {
        let binding = bindingRevision
        let publication = UUID()
        refreshPublicationRevision = publication
        do {
            let capability = try await discoverCapability()
            let snapshot: LoadedPractice
            if capability.supportsLinkedExtensions {
                var loaded: LoadedPractice?
                for pass in 0..<2 {
                    do { loaded = try await linkedSnapshot(using: client, capability: capability); break }
                    catch let failure as APIFailure {
                        if case .refused(let code, _, _) = failure, code == "READ_SNAPSHOT_CHANGED", pass == 0 { continue }
                        throw failure
                    }
                }
                guard let loaded else { throw APIFailure.unreachable("The practice kept changing. Try refreshing again.") }
                snapshot = loaded
            } else { snapshot = try await legacySnapshot(using: client) }
            let sankalpas = snapshot.vows
            let sessions = snapshot.facts
            guard binding == bindingRevision,
                  publication == refreshPublicationRevision
            else { return }
            let saved = cache.saveCache(CachedPractice(serviceLocation: location.displayText, sankalpas: sankalpas,
                    sessions: sessions, serviceInstanceId: capability.serviceInstanceId,
                    practiceRevision: snapshot.revision))
            if !saved && capability.supportsLinkedExtensions { throw APIFailure.unreachable("The refreshed practice could not be saved on this device.") }
            cachedServiceInstanceId = capability.serviceInstanceId
            serverPracticeRevision = snapshot.revision
            completeBaseSnapshot = true
            store.replace(sankalpas: sankalpas, sessions: sessions)
            applyOperations()
            hasLoaded = true
            isShowingCachedPractice = false
            isServiceReachable = true
            refreshFailure = nil
        } catch let failure as APIFailure {
            guard binding == bindingRevision,
                  publication == refreshPublicationRevision
            else { return }
            isServiceReachable = false
            isShowingCachedPractice = hasLoaded
            assistantCapability = nil
            refreshFailure = failure.fallbackMessage
            syncLog.notice("Refresh failed: \(self.refreshFailure ?? "", privacy: .public)")
        } catch let failure as WireDecodingError {
            guard binding == bindingRevision,
                  publication == refreshPublicationRevision
            else { return }
            isServiceReachable = false
            isShowingCachedPractice = hasLoaded
            assistantCapability = nil
            refreshFailure = failure.message
            syncLog.notice("Refresh failed: \(self.refreshFailure ?? "", privacy: .public)")
        } catch {
            guard binding == bindingRevision,
                  publication == refreshPublicationRevision
            else { return }
            isServiceReachable = false
            isShowingCachedPractice = hasLoaded
            assistantCapability = nil
            refreshFailure = "Your practice could not be reached right now. Try again."
            syncLog.notice("Refresh failed: \(self.refreshFailure ?? "", privacy: .public)")
        }
    }

    private struct LoadedPractice { let vows: [Sankalpa]; let facts: [Session]; let revision: String? }

    private func legacySnapshot(using legacyClient: SankalpaAPIClient) async throws -> LoadedPractice {
            let listed = try await legacyClient.list()
            let loaded = try await withThrowingTaskGroup(of: LoadedSankalpa.self) { group in
                for dto in listed {
                    group.addTask {
                        let id = SankalpaId(dto.id)
                        async let history = legacyClient.lifecycleHistory(id)
                        let sessions = try await Self.allSessions(for: id, using: legacyClient)
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
        guard Set(sankalpas.map(\.id)).count == sankalpas.count else { throw PracticeValidation.Invalid.collection }
        return LoadedPractice(vows: sankalpas, facts: sessions, revision: nil)
    }

    private func linkedSnapshot(using readClient: SankalpaAPIClient, capability: ServiceCapability) async throws -> LoadedPractice {
        let response = try await readClient.linkedList()
        let pinned = readClient.linked(to: capability.serviceInstanceId, revision: response.revision)
        let listed = response.value
        guard Set(listed.map(\.id)).count == listed.count else { throw PracticeValidation.Invalid.collection }
        var vows: [Sankalpa] = []
        for dto in listed {
            let history = try await pinned.lifecycleHistory(SankalpaId(dto.id))
            vows.append(try APIMapping.sankalpa(dto, transitions: history, linked: true))
        }
        var rows: [API.SessionResponse] = []; var token: String?; var tokens = Set<String>()
        repeat {
            let page = try await pinned.canonicalSessions(cursor: token).value
            guard page.hasMore == (page.nextCursor != nil), !page.hasMore || !page.content.isEmpty else { throw PracticeValidation.Invalid.collection }
            rows.append(contentsOf: page.content)
            token = page.nextCursor
            if let token, !tokens.insert(token).inserted { throw PracticeValidation.Invalid.collection }
        } while token != nil
        let facts = try rows.map(APIMapping.session)
        try PracticeValidation.validate(vows, sessions: facts)
        for (dto, fact) in zip(rows, facts) {
            guard dto.loggingSankalpaId == fact.sankalpaId.value,
                  dto.contributingSankalpaIds == SessionContributions.contributors(fact, members: vows).map({ $0.id.value })
            else { throw PracticeValidation.Invalid.collection }
        }
        for (dto, vow) in zip(listed, vows) {
            guard dto.totalSessionCount == facts.count(where: { SessionContributions.contributes($0, to: vow, members: vows) }),
                  dto.directExtensionId == vows.first(where: { $0.extensionOf == vow.id })?.id.value else { throw PracticeValidation.Invalid.collection }
        }
        return LoadedPractice(vows: vows, facts: facts, revision: response.revision)
    }

    public func sync() async {
        do {
            let capability = try await discoverCapability()
            await flushOperations(capability: capability)
            if capability.supportsLinkedExtensions { _ = await deliverExtension() }
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
            } catch is WireDecodingError {
                _ = quarantine(create)
                return
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

        if linkedSeries(id).count > 1 && !capability.supportsLinkedExtensions {
            return .rejected(.storage(.unavailable("Update the service before logging linked sessions.")))
        }
        guard cachedServiceInstanceId == nil || cachedServiceInstanceId == capability.serviceInstanceId else {
            return .rejected(.storage(.unavailable("Refresh the current service before starting a session.")))
        }
        if supportsLinkedExtensions && journal.recentLogs.contains(where: {
            let elapsed = $0.acceptedAt.day.days(until: clock.now().day) * CalendarMoment.secondsPerDay
                + clock.now().secondOfDay - $0.acceptedAt.secondOfDay
            return (0..<60).contains(elapsed) && store.find($0.sankalpaId) == nil
        }) {
            return .rejected(.storage(.unavailable("Refresh linked membership before starting another session.")))
        }
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
        } catch is WireDecodingError {
            _ = quarantine(entry)
            return .pending(SessionReceipt(session: entry.session, status: .pending))
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

        guard cachedServiceInstanceId == nil || cachedServiceInstanceId == capability.serviceInstanceId else {
            return .rejected(.storage(.unavailable("Refresh the current service before deleting a session.")))
        }
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

    public func shouldConfirmRepeat(for id: SankalpaId, excluding sessionId: SessionId? = nil) -> Bool {
        let suppressed = Set(journal.deletions.map(\.id))
        guard let last = journal.recentLogs.last(where: {
            seriesId(for: $0.sankalpaId) == seriesId(for: id) && $0.sessionId != sessionId && !suppressed.contains($0.sessionId)
        }) else { return false }
        let seconds = last.acceptedAt.day.days(until: clock.now().day) * CalendarMoment.secondsPerDay
            + clock.now().secondOfDay - last.acceptedAt.secondOfDay
        return (0..<60).contains(seconds)
    }

    public func prepareAssistantConfirmation(owner: SankalpaId, sessionId: SessionId) -> Bool {
        guard store.find(owner) != nil, cache.outboxProblem == nil else { return false }
        if journal.recentLogs.contains(where: { $0.sessionId == sessionId }) { return true }
        var proposed = journal
        proposed.recentLogs.append(RecentSessionLog(sessionId: sessionId, sankalpaId: owner, acceptedAt: clock.now()))
        return persistJournal(proposed)
    }

    private func completeCreate(
        _ entry: PendingSession, response: API.SessionResponse
    ) throws -> Session {
        guard response.id == entry.id.value,
              response.sankalpaId == entry.sankalpaId.value,
              response.loggingSankalpaId == nil || response.loggingSankalpaId == entry.sankalpaId.value,
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
        syncLog.notice("Service rejected pending session: \(failure.fallbackMessage, privacy: .public)")
        return persistJournal(proposed)
    }

    @discardableResult
    private func rejectDeletion(_ entry: PendingSessionDeletion, failure: APIFailure) -> Bool {
        guard journal.deletions.contains(where: { $0.id == entry.id && $0.revision == entry.revision })
        else { return false }
        var proposed = journal
        proposed.deletions.removeAll { $0.id == entry.id && $0.revision == entry.revision }
        proposed.notices.append("The session could not be deleted. \(failure.fallbackMessage)")
        syncLog.notice("Service rejected pending deletion: \(failure.fallbackMessage, privacy: .public)")
        return persistJournal(proposed)
    }

    private func recordNotice(_ text: String) {
        syncLog.notice("\(text, privacy: .public)")
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
        syncLog.error("Quarantined pending session \(entry.id.value.uuidString, privacy: .public): the service response did not match it")
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

    // MARK: - Durable linked extension

    @discardableResult
    public func acknowledgeExtensionNotice() -> Bool {
        guard extensionAttempt?.state == .resolvedNotice else { return false }
        guard cache.removeExtensionAttempt() else { return false }
        extensionAttempt = nil
        return true
    }

    private func persistAttempt(_ candidate: ExtensionAttempt) -> Bool {
        guard cache.saveExtensionAttempt(candidate) else { return false }
        extensionAttempt = candidate
        return true
    }

    public func extend(_ sourceId: SankalpaId, totalPeriodCount: Int) async -> ExtensionDisposition {
        guard cache.outboxProblem == nil else {
            return .refused("Recover preserved session changes before extending this practice.")
        }
        guard !hasExtensionAttempt else { return .pending(extensionNotice ?? "Resolve the submitted extension before creating another.") }
        guard let source = store.find(sourceId) else { return .refused("Refresh this sankalpa before extending it.") }
        guard !store.all().contains(where: { $0.extensionOf == sourceId }) else { return .refused("This sankalpa already has an extension. Open that vow to extend it further.") }
        do { _ = try source.extended(totalPeriodCount: totalPeriodCount, now: clock.now()) }
        catch let error as any DomainError { return .refused(error.message) }
        catch { return .refused("Check the proposed total duration.") }
        let capability: ServiceCapability
        do {
            capability = try await discoverCapability()
            guard isServiceReachable, capability.supportsLinkedExtensions else {
                return .refused("Connect to a service supporting linked extensions before submitting.")
            }
        } catch { return .refused("Extension creation needs a connection to the Sankalpa service.") }
        // Awaiting capability can let another form submit. Claim the single durable slot now.
        guard !hasExtensionAttempt else { return .pending("An extension is already awaiting a result.") }
        guard cachedServiceInstanceId == capability.serviceInstanceId, store.find(sourceId) != nil else {
            return .refused("Refresh this sankalpa from its current service before extending it.")
        }
        let attempt = ExtensionAttempt(instance: capability.serviceInstanceId, source: source,
                                       totalPeriodCount: totalPeriodCount, submittedAt: clock.now())
        guard persistAttempt(attempt) else { return .refused("The extension attempt could not be saved. Nothing was sent.") }
        return await deliverExtension()
    }

    public func retryExtension() async -> ExtensionDisposition {
        do { _ = try await discoverCapability() }
        catch { return .pending(extensionNotice ?? "The extension is awaiting its original service.") }
        return await deliverExtension()
    }

    private func deliverExtension() async -> ExtensionDisposition {
        guard let attempt = extensionAttempt else { return .refused(cache.extensionProblem ?? "No extension is awaiting a result.") }
        if attempt.state == .resolvedNotice { return .refused(attempt.notice ?? "The extension was resolved.") }
        if attempt.state == .blockedConflict { return .blocked(attempt.notice ?? "The extension needs recovery.") }
        guard !extensionDelivering else { return .pending("The extension is being checked.") }
        guard journal.capability?.serviceInstanceId == attempt.serviceInstanceId,
              journal.capability?.supportsLinkedExtensions == true else {
            return .pending("The extension is awaiting its original service with linked support.")
        }
        extensionDelivering = true
        defer { extensionDelivering = false }
        let binding = bindingRevision
        let deliveryClient = client.linked(to: attempt.serviceInstanceId)
        do {
            if attempt.state == .acceptedAwaitingCache,
               let accepted = attempt.acceptedResponse, let revision = attempt.acceptedRevision,
               revisionIsCurrent(revision) {
                return try cacheAcceptedExtension(attempt, response: accepted, revision: revision)
            }
            let response = try await deliveryClient.extend(attempt.sourceId, id: attempt.extensionId,
                                                           totalPeriodCount: attempt.totalPeriodCount)
            guard binding == bindingRevision, extensionAttempt?.revision == attempt.revision else { return .pending("The submitted extension is still being checked.") }
            return try retainAcceptedExtension(attempt, response: response.value, revision: response.revision, existing: false)
        } catch let conflict as ExistingExtensionConflict {
            do {
                let series = try await deliveryClient.linkedSeries(conflict.id)
                guard binding == bindingRevision, extensionAttempt?.revision == attempt.revision,
                      let child = series.value.first(where: { $0.sankalpa.id == conflict.id.value }),
                      child.sankalpa.extensionOf == attempt.sourceId.value else { throw PracticeValidation.Invalid.collection }
                let result = API.ExtensionResponse(created: false, sankalpa: child.sankalpa, series: series.value)
                return try retainAcceptedExtension(attempt, response: result, revision: series.revision, existing: true)
            } catch { return updateAttempt(attempt, state: .unresolved, notice: "An extension already exists; its history is awaiting confirmation from the service.") }
        } catch let failure as APIFailure {
            if case .refused(let code, _, let status) = failure,
               ["SOURCE_NOT_EXTENDABLE", "DURATION_NOT_GREATER", "EXTENSION_ENDS_IN_PAST", "INVALID_EXTENSION_REQUEST", "SANKALPA_NOT_FOUND"].contains(code),
               [400, 404, 422].contains(status) {
                return updateAttempt(attempt, state: .resolvedNotice, notice: failure.fallbackMessage)
            }
            if case .refused(let code, _, _) = failure, code == "EXTENSION_IDENTITY_CONFLICT" {
                return updateAttempt(attempt, state: .blockedConflict, notice: "The service has different input for this extension identity. The attempt was preserved for recovery.")
            }
            return updateAttempt(attempt, state: .unresolved, notice: "The extension result is pending. Retry checks the same submitted request.")
        } catch is WireDecodingError {
            return updateAttempt(attempt, state: .blockedConflict, notice: "The extension response did not match its service contract. The attempt was preserved for recovery.")
        } catch is PracticeValidation.Invalid {
            return updateAttempt(attempt, state: .blockedConflict, notice: "The extension response did not match the submitted vow. The attempt was preserved for recovery.")
        } catch {
            // An accepted response/cache failure must retain its accepted data and identity.
            if extensionAttempt?.state == .acceptedAwaitingCache {
                return .pending("The extension was accepted. Its saved result is waiting to be cached on this device.")
            }
            return updateAttempt(attempt, state: .unresolved, notice: "The extension result is pending. Retry checks the same submitted request.")
        }
    }

    private func updateAttempt(_ attempt: ExtensionAttempt, state: ExtensionAttempt.State, notice: String) -> ExtensionDisposition {
        guard extensionAttempt?.revision == attempt.revision else { return .pending(notice) }
        var next = extensionAttempt ?? attempt; next.state = state; next.notice = notice
        _ = persistAttempt(next)
        switch state {
        case .resolvedNotice: return .refused(notice)
        case .blockedConflict: return .blocked(notice)
        default: return .pending(notice)
        }
    }

    private func retainAcceptedExtension(_ attempt: ExtensionAttempt, response: API.ExtensionResponse,
                                         revision: String, existing: Bool) throws -> ExtensionDisposition {
        try validateAcceptedExtension(attempt, response: response, existing: existing)
        let child = response.sankalpa
        var next = attempt
        next.state = .acceptedAwaitingCache; next.acceptedResponse = response; next.acceptedRevision = revision
        next.existingChild = existing; next.notice = existing ? "This sankalpa already has a \(child.periodCount ?? 0)-period extension. That existing vow was opened; the requested duration was not created." : nil
        guard persistAttempt(next) else { throw PersistenceError.writeFailed }
        return try cacheAcceptedExtension(next, response: response, revision: revision)
    }

    private func validateAcceptedExtension(_ attempt: ExtensionAttempt, response: API.ExtensionResponse, existing: Bool) throws {
        let child = response.sankalpa
        guard child.extensionOf == attempt.sourceId.value, child.seriesId == attempt.seriesId.value,
              existing || (child.id == attempt.extensionId.value && child.periodCount == attempt.totalPeriodCount),
              response.series.contains(where: { $0.sankalpa.id == child.id }),
              response.series.allSatisfy({ $0.sankalpa.seriesId == attempt.seriesId.value }) else { throw PracticeValidation.Invalid.collection }
        let members = try response.series.map { try APIMapping.sankalpa($0.sankalpa, transitions: $0.lifecycleHistory, linked: true) }
        try PracticeValidation.validate(members, sessions: [])
        guard let accepted = members.first(where: { $0.id.value == child.id }), accepted.extensionOf == attempt.sourceId,
              response.series.first(where: { $0.sankalpa.id == child.id })?.sankalpa == child else { throw PracticeValidation.Invalid.collection }
    }

    private func revisionIsCurrent(_ revision: String) -> Bool {
        guard let value = Int64(revision), value >= 0 else { return false }
        guard let current = serverPracticeRevision else { return true }
        guard let base = Int64(current) else { return false }
        return value >= base
    }

    private func cacheAcceptedExtension(_ attempt: ExtensionAttempt, response: API.ExtensionResponse, revision: String) throws -> ExtensionDisposition {
        guard extensionAttempt?.revision == attempt.revision else { throw PersistenceError.writeFailed }
        try validateAcceptedExtension(attempt, response: response, existing: attempt.existingChild)
        if !revisionIsCurrent(revision) {
            return .pending("A newer practice is cached. Retry will fetch the current extension result.")
        }
        let members = try response.series.map { try APIMapping.sankalpa($0.sankalpa, transitions: $0.lifecycleHistory, linked: true) }
        let base = store.snapshot()
        let vows = base.sankalpas.filter { $0.seriesId != attempt.seriesId } + members
        try PracticeValidation.validate(vows, sessions: base.sessions)
        refreshPublicationRevision = UUID()
        guard cache.saveCache(CachedPractice(serviceLocation: location.displayText, sankalpas: vows, sessions: base.sessions,
                serviceInstanceId: attempt.serviceInstanceId, practiceRevision: revision, completeSnapshot: false)) else { throw PersistenceError.writeFailed }
        store.replace(sankalpas: vows, sessions: base.sessions); applyOperations()
        cachedServiceInstanceId = attempt.serviceInstanceId
        serverPracticeRevision = revision; completeBaseSnapshot = false; hasLoaded = true
        isShowingCachedPractice = true
        if attempt.existingChild {
            var resolved = attempt; resolved.state = .resolvedNotice
            guard persistAttempt(resolved) else { throw PersistenceError.writeFailed }
        } else {
            guard cache.removeExtensionAttempt() else { throw PersistenceError.writeFailed }
            extensionAttempt = nil
        }
        return .accepted(SankalpaId(response.sankalpa.id), existingChild: attempt.existingChild)
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
        if linkedSeries(id).count > 1 {
            guard supportsLinkedExtensions, cachedServiceInstanceId == journal.capability?.serviceInstanceId else {
                return .storage(.unavailable("Refresh from a service supporting linked practice before changing this vow."))
            }
        }
        do {
            let response = try await command()
            if linkedSeries(id).count > 1,
               response.id != id.value || APIEnum.lifecycleState(response.lifecycleState) != target {
                return .storage(.unavailable("The service did not confirm the requested lifecycle change. Refresh this vow before trying again."))
            }
        }
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
