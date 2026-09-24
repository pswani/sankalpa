import Foundation
import SankalpaCore

/// A create command accepted on this device but not yet conclusively accepted or rejected by its
/// originating service. Its id is also the eventual session id and is reused by every retry.
public struct PendingSession: Codable, Hashable, Sendable, Identifiable {
    public let id: SessionId
    public let sankalpaId: SankalpaId
    public let occurredAt: CalendarMoment
    public let loggedAt: CalendarMoment
    public let serviceInstanceId: UUID?
    public let revision: UUID

    public init(
        id: SessionId = SessionId(), sankalpaId: SankalpaId,
        occurredAt: CalendarMoment, loggedAt: CalendarMoment,
        serviceInstanceId: UUID? = nil, revision: UUID = UUID()
    ) {
        self.id = id
        self.sankalpaId = sankalpaId
        self.occurredAt = occurredAt
        self.loggedAt = loggedAt
        self.serviceInstanceId = serviceInstanceId
        self.revision = revision
    }

    public var session: Session {
        Session.rehydrate(id: id, sankalpaId: sankalpaId, occurredAt: occurredAt, loggedAt: loggedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, sankalpaId, occurredAt, loggedAt, serviceInstanceId, revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(SessionId.self, forKey: .id)
        sankalpaId = try values.decode(SankalpaId.self, forKey: .sankalpaId)
        occurredAt = try values.decode(CalendarMoment.self, forKey: .occurredAt)
        loggedAt = try values.decode(CalendarMoment.self, forKey: .loggedAt)
        serviceInstanceId = try values.decodeIfPresent(UUID.self, forKey: .serviceInstanceId)
        revision = try values.decodeIfPresent(UUID.self, forKey: .revision) ?? UUID()
    }
}

public struct PendingSessionDeletion: Codable, Hashable, Sendable, Identifiable {
    public let id: SessionId
    public let sankalpaId: SankalpaId
    public let occurredAt: CalendarMoment
    public let serviceInstanceId: UUID
    public let requestedAt: CalendarMoment
    public let revision: UUID

    public init(
        id: SessionId, sankalpaId: SankalpaId, occurredAt: CalendarMoment,
        serviceInstanceId: UUID,
        requestedAt: CalendarMoment, revision: UUID = UUID()
    ) {
        self.id = id
        self.sankalpaId = sankalpaId
        self.occurredAt = occurredAt
        self.serviceInstanceId = serviceInstanceId
        self.requestedAt = requestedAt
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id, sankalpaId, occurredAt, serviceInstanceId, requestedAt, revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(SessionId.self, forKey: .id)
        sankalpaId = try values.decode(SankalpaId.self, forKey: .sankalpaId)
        requestedAt = try values.decode(CalendarMoment.self, forKey: .requestedAt)
        occurredAt = try values.decodeIfPresent(CalendarMoment.self, forKey: .occurredAt)
            ?? requestedAt
        serviceInstanceId = try values.decode(UUID.self, forKey: .serviceInstanceId)
        revision = try values.decodeIfPresent(UUID.self, forKey: .revision) ?? UUID()
    }
}

struct ServiceCapability: Codable, Hashable, Sendable {
    let sessionCommandIdentity: Int
    let serviceInstanceId: UUID
    var supportsReliableSessions: Bool { sessionCommandIdentity >= 1 }
}

struct RecentSessionLog: Codable, Hashable, Sendable {
    let sessionId: SessionId
    let sankalpaId: SankalpaId
    /// The durable-pending/completion time, not the performed-at time.
    let acceptedAt: CalendarMoment
}

struct ReliabilityJournal: Codable, Sendable {
    var schemaVersion = 2
    var serviceLocation: String
    var capability: ServiceCapability?
    var creates: [PendingSession] = []
    var deletions: [PendingSessionDeletion] = []
    var quarantinedCreates: [SessionId] = []
    var recentLogs: [RecentSessionLog] = []
    var notices: [String] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, serviceLocation, capability, creates, deletions, quarantinedCreates
        case recentLogs, notices
    }

    init(serviceLocation: String) { self.serviceLocation = serviceLocation }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        serviceLocation = try values.decode(String.self, forKey: .serviceLocation)
        capability = try values.decodeIfPresent(ServiceCapability.self, forKey: .capability)
        creates = try values.decodeIfPresent([PendingSession].self, forKey: .creates) ?? []
        deletions = try values.decodeIfPresent([PendingSessionDeletion].self, forKey: .deletions) ?? []
        quarantinedCreates = try values.decodeIfPresent(
            [SessionId].self, forKey: .quarantinedCreates
        ) ?? []
        recentLogs = try values.decodeIfPresent([RecentSessionLog].self, forKey: .recentLogs) ?? []
        notices = try values.decodeIfPresent([String].self, forKey: .notices) ?? []
    }
}

/// Complete session history from the last successful refresh. Schema-1 counts remain decodable
/// during rollout, but schema 2 derives every total from `sessions`.
struct CachedPractice: Codable, Sendable {
    var schemaVersion = 2
    var serviceLocation: String
    var sankalpas: [Sankalpa]
    var sessions: [Session]
    var counts: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, serviceLocation, sankalpas, sessions, counts
    }

    init(serviceLocation: String, sankalpas: [Sankalpa], sessions: [Session]) {
        self.serviceLocation = serviceLocation
        self.sankalpas = sankalpas
        self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        serviceLocation = try values.decode(String.self, forKey: .serviceLocation)
        sankalpas = try values.decode([Sankalpa].self, forKey: .sankalpas)
        sessions = try values.decode([Session].self, forKey: .sessions)
        counts = try values.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
    }
}

/// Durable operations are separated from the disposable server snapshot. An unreadable journal
/// is preserved in place and blocks new session mutations instead of being silently replaced.
public final class PracticeCache {
    private let directory: URL
    private let writer: (Data, URL) throws -> Void
    public private(set) var outboxProblem: String?

    public init(
        directory: URL = PracticeCache.defaultDirectory(),
        writer: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.directory = directory
        self.writer = writer
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var cacheURL: URL { directory.appendingPathComponent("sankalpa-cache.json") }
    private var journalURL: URL { directory.appendingPathComponent("sankalpa-outbox.json") }

    func loadCache(for location: ServiceLocation) -> CachedPractice? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedPractice.self, from: data),
              cached.schemaVersion <= 2,
              cached.serviceLocation == location.displayText
        else { return nil }
        return cached
    }

    @discardableResult
    func saveCache(_ practice: CachedPractice) -> Bool {
        guard let data = try? JSONEncoder().encode(practice) else { return false }
        do { try writer(data, cacheURL); return true } catch { return false }
    }

    func loadJournal(for location: ServiceLocation) -> ReliabilityJournal {
        let empty = ReliabilityJournal(serviceLocation: location.displayText)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return empty }
        guard let data = try? Data(contentsOf: journalURL) else {
            preserveUnreadableJournal()
            return empty
        }
        if let journal = try? JSONDecoder().decode(ReliabilityJournal.self, from: data),
           journal.schemaVersion == 2, isValid(journal) {
            return journal
        }
        if (try? JSONDecoder().decode([PendingSession].self, from: data)) != nil {
            preserveUnreadableJournal(message: "Older pending sessions need recovery before session changes can continue.")
        } else {
            preserveUnreadableJournal()
        }
        return empty
    }

    @discardableResult
    func saveJournal(_ journal: ReliabilityJournal) -> Bool {
        guard outboxProblem == nil, isValid(journal),
              let data = try? JSONEncoder().encode(journal)
        else { return false }
        do { try writer(data, journalURL); return true } catch { return false }
    }

    /// Compatibility helpers for code that only needs to inspect pending creates.
    public func loadOutbox() -> [PendingSession] {
        loadJournal(for: ServiceLocation(host: "localhost", port: 8080)).creates
    }

    @discardableResult
    func saveOutbox(_ pending: [PendingSession]) -> Bool {
        var journal = loadJournal(for: ServiceLocation(host: "localhost", port: 8080))
        journal.creates = pending
        return saveJournal(journal)
    }

    private func preserveUnreadableJournal(
        message: String = "Pending session changes could not be read. They were preserved, and session changes are blocked until they are recovered."
    ) {
        outboxProblem = message
    }

    /// Explicitly replaces preserved unreadable/legacy operations after a warned user decision.
    /// Nothing calls this automatically: recovery must never turn data loss into a side effect of
    /// launch, refresh, or another mutation.
    func discardUnrecoverableJournal(for location: ServiceLocation) -> ReliabilityJournal? {
        guard outboxProblem != nil,
              let data = try? JSONEncoder().encode(
                ReliabilityJournal(serviceLocation: location.displayText)
              )
        else { return nil }
        do {
            try writer(data, journalURL)
            outboxProblem = nil
            return ReliabilityJournal(serviceLocation: location.displayText)
        } catch {
            return nil
        }
    }

    private func isValid(_ journal: ReliabilityJournal) -> Bool {
        let createIds = journal.creates.map(\.id)
        let deleteIds = journal.deletions.map(\.id)
        let allIds = createIds + deleteIds
        guard Set(allIds).count == allIds.count else { return false }
        guard Set(journal.quarantinedCreates).count == journal.quarantinedCreates.count,
              Set(journal.quarantinedCreates).isSubset(of: Set(createIds))
        else { return false }
        guard journal.creates.allSatisfy({ $0.serviceInstanceId != nil }) else { return false }
        guard let expected = journal.capability?.serviceInstanceId else {
            return allIds.isEmpty
        }
        return journal.creates.allSatisfy { $0.serviceInstanceId == expected }
            && journal.deletions.allSatisfy { $0.serviceInstanceId == expected }
    }

    public static func removeEverything(in directory: URL = PracticeCache.defaultDirectory()) {
        for name in ["sankalpa-cache.json", "sankalpa-outbox.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
