import Foundation
import SankalpaCore

/// A session logged on the phone that the service has not accepted yet.
///
/// Its id is also the command identity sent to current services, so a retry cannot create another
/// session. `hasAuthoritativeID` is optional only so outboxes written by older app versions still
/// decode; those entries used a provisional id that the service did not preserve.
public struct PendingSession: Codable, Hashable, Sendable, Identifiable {
    public let id: SessionId
    public let sankalpaId: SankalpaId
    public let occurredAt: CalendarMoment
    public let loggedAt: CalendarMoment
    public let hasAuthoritativeID: Bool?

    public init(
        id: SessionId = SessionId(),
        sankalpaId: SankalpaId,
        occurredAt: CalendarMoment,
        loggedAt: CalendarMoment,
        hasAuthoritativeID: Bool? = true
    ) {
        self.id = id
        self.sankalpaId = sankalpaId
        self.occurredAt = occurredAt
        self.loggedAt = loggedAt
        self.hasAuthoritativeID = hasAuthoritativeID
    }

    /// What the screens render it as while it waits. It is a real session as far as the period
    /// arithmetic is concerned — that is the point of logging it offline.
    public var session: Session {
        Session.rehydrate(
            id: id, sankalpaId: sankalpaId, occurredAt: occurredAt, loggedAt: loggedAt
        )
    }
}

/// What the last successful refresh returned, kept so the app has something to show when the
/// service cannot be reached.
struct CachedPractice: Codable, Sendable {
    var schemaVersion = 1
    /// Which service this came from. Pointing the app at a different computer makes it someone
    /// else's practice, so it is discarded rather than shown.
    var serviceLocation: String
    var sankalpas: [Sankalpa]
    var sessions: [Session]
    /// Lifetime counts as the service reported them, which can exceed the sessions held here
    /// because session history is read a bounded number of pages deep.
    var counts: [String: Int]
}

/// The two files the app keeps on the phone, and the difference between them.
///
/// The **cache** is a copy of what the service said last time. Losing it costs a round trip and
/// nothing else, so a cache that cannot be read is simply discarded.
///
/// The **outbox** is the opposite: it holds sessions that exist nowhere else until the service
/// takes them. Losing it loses someone's practice, so a file that cannot be read is renamed and
/// kept rather than written over — the same answer the app has always given to bytes it cannot
/// parse, and the reason the two are separate files at all. A corrupt cache must not be able to
/// take the outbox with it.
public final class PracticeCache {
    private let directory: URL
    private let writer: (Data, URL) throws -> Void

    /// Set when the outbox could not be read and was set aside, so the app can say so once.
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
    private var outboxURL: URL { directory.appendingPathComponent("sankalpa-outbox.json") }

    // MARK: - Cache

    /// The cached practice, or `nil` when there is none this app can use — no file yet, a file it
    /// cannot read, or one belonging to a different service.
    func loadCache(for location: ServiceLocation) -> CachedPractice? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedPractice.self, from: data),
              cached.schemaVersion <= 1,
              cached.serviceLocation == location.displayText
        else { return nil }
        return cached
    }

    func saveCache(_ practice: CachedPractice) {
        guard let data = try? JSONEncoder().encode(practice) else { return }
        // A cache that cannot be written is not worth telling anyone about: the app has the data
        // in memory, and the only cost is a round trip after the next launch.
        try? writer(data, cacheURL)
    }

    // MARK: - Outbox

    public func loadOutbox() -> [PendingSession] {
        guard FileManager.default.fileExists(atPath: outboxURL.path) else { return [] }
        guard let data = try? Data(contentsOf: outboxURL),
              let pending = try? JSONDecoder().decode([PendingSession].self, from: data)
        else {
            setAsideUnreadableOutbox()
            return []
        }
        return pending
    }

    /// Returns whether the outbox reached the disk. A caller that has just accepted a session
    /// offline needs to know: reporting it as logged when it is only in memory would lose it on
    /// the next launch, which is the one thing this file exists to prevent.
    @discardableResult
    func saveOutbox(_ pending: [PendingSession]) -> Bool {
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        do {
            try writer(data, outboxURL)
            return true
        } catch {
            return false
        }
    }

    /// Renames a damaged outbox instead of deleting it, and says so. Starting fresh is what keeps
    /// the app usable; keeping the bytes is what makes that honest.
    private func setAsideUnreadableOutbox() {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = directory.appendingPathComponent("sankalpa-outbox-damaged-\(stamp).json")
        try? FileManager.default.moveItem(at: outboxURL, to: destination)
        outboxProblem = """
            Some sessions were waiting to reach the Sankalpa service and could not be read. \
            They have been kept in a file named sankalpa-outbox-damaged-\(stamp).json rather than \
            deleted, and logging has started again from empty.
            """
    }

    public func clearOutboxProblem() { outboxProblem = nil }

    /// Removes the cache and the outbox. This is for a test run starting from nothing — the same
    /// job the store file's reset used to do — and is never part of using the app: the whole point
    /// of both files is that they survive.
    public static func removeEverything(in directory: URL = PracticeCache.defaultDirectory()) {
        for name in ["sankalpa-cache.json", "sankalpa-outbox.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
