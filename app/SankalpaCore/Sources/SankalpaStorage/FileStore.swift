import Foundation
import SankalpaCore

/// The single JSON file that holds everything, for a single-user local app.
///
/// Two invariants hold, and they are the point of this type:
///
/// 1. **A change is published in memory only after it reaches disk.** A failed write throws and
///    leaves both the in-memory state and the file exactly as they were.
/// 2. **A file that could not be read is never written over.** An unreadable store puts the app
///    into a read-only state instead of quietly starting empty — which would otherwise look
///    identical to a fresh install and invite seeding over the user's history.
public final class FileStore: SankalpaRepository, SessionRepository {
    private struct Snapshot: Codable {
        var schemaVersion = 1
        var sankalpas: [Sankalpa] = []
        var sessions: [Session] = []
    }

    public let fileURL: URL
    private var snapshot = Snapshot()
    /// Kept alongside the sessions so a lifetime count never scans history.
    private var counts: [SankalpaId: Int] = [:]

    /// Non-nil when the file exists but could not be used. While it is set, every write is refused.
    public private(set) var loadError: String?

    /// Injected so a test can make the disk fail without mocking a filesystem.
    private let writer: (Data, URL) throws -> Void

    public init(
        fileURL: URL,
        writer: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.writer = writer
        reload()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sankalpa-store.json")
    }

    /// True only for a genuinely new store — an empty file that loaded cleanly. A load failure is
    /// deliberately not "empty", because that is how data gets overwritten.
    public var isNew: Bool { loadError == nil && snapshot.sankalpas.isEmpty && snapshot.sessions.isEmpty }

    // MARK: - Loading

    public func reload() {
        do {
            let data = try Data(contentsOf: fileURL)
            let candidate = try JSONDecoder().decode(Snapshot.self, from: data)
            guard candidate.schemaVersion <= 1 else {
                loadError = """
                    This practice was saved by a newer version of the app. Update the app to open \
                    it. The original file has been left untouched.
                    """
                return
            }
            publish(candidate)
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No file yet is a fresh install, not a failure.
            publish(Snapshot())
            loadError = nil
        } catch {
            loadError = """
                Your saved practice could not be opened. Nothing has been changed or deleted, so \
                the original file is still there.
                """
        }
    }

    /// True once anything has been written, so a caller knows whether there is a file to hand to
    /// the user at all.
    public var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Moves an unreadable file aside and opens an empty store in its place.
    ///
    /// Refusing to write over a file that will not parse is right, but on its own it leaves the
    /// app with nothing it can do: every write is refused, so there is no way back to a usable
    /// app except deleting it, which destroys the very bytes the recovery screen promises are
    /// still there. This keeps that promise and still lets the user carry on — the damaged file
    /// is renamed, never deleted, and its new location is returned so it can be shown or shared.
    @discardableResult
    public func setAsideUnreadableFile() throws -> URL {
        guard loadError != nil else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("sankalpa-store-damaged-\(stamp).json")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        // With the file gone, this takes the fresh-install path: an empty store, no load error.
        reload()
        return destination
    }

    // MARK: - SankalpaRepository

    public func all() -> [Sankalpa] { snapshot.sankalpas }

    public func find(_ id: SankalpaId) -> Sankalpa? {
        snapshot.sankalpas.first { $0.id == id }
    }

    public func save(_ sankalpa: Sankalpa) throws(PersistenceError) {
        var candidate = snapshot
        if let index = candidate.sankalpas.firstIndex(where: { $0.id == sankalpa.id }) {
            candidate.sankalpas[index] = sankalpa
        } else {
            candidate.sankalpas.append(sankalpa)
        }
        try commit(candidate)
    }

    // MARK: - SessionRepository

    public func save(_ session: Session) throws(PersistenceError) {
        var candidate = snapshot
        candidate.sessions.append(session)
        try commit(candidate)
    }

    @discardableResult
    public func delete(_ sessionId: SessionId) throws(PersistenceError) -> Bool {
        guard snapshot.sessions.contains(where: { $0.id == sessionId }) else { return false }
        var candidate = snapshot
        candidate.sessions.removeAll { $0.id == sessionId }
        try commit(candidate)
        return true
    }

    public func sessions(
        for sankalpaId: SankalpaId, from: CalendarDay, until: CalendarDay
    ) -> [Session] {
        guard from <= until else { return [] }
        return snapshot.sessions.filter {
            $0.sankalpaId == sankalpaId && $0.occurredAt.day >= from && $0.occurredAt.day <= until
        }
    }

    public func sessions(from: CalendarDay, until: CalendarDay) -> [Session] {
        guard from <= until else { return [] }
        return snapshot.sessions.filter {
            $0.occurredAt.day >= from && $0.occurredAt.day <= until
        }
    }

    public func totalCount(for sankalpaId: SankalpaId) -> Int { counts[sankalpaId] ?? 0 }

    // MARK: - Bulk operations

    public func replaceAll(sankalpas: [Sankalpa], sessions: [Session]) throws(PersistenceError) {
        try commit(Snapshot(sankalpas: sankalpas, sessions: sessions))
    }

    public func clear() throws(PersistenceError) {
        try commit(Snapshot())
    }

    // MARK: - Committing

    private func commit(_ candidate: Snapshot) throws(PersistenceError) {
        if let loadError { throw .unavailable(loadError) }

        let data: Data
        do {
            data = try encode(candidate)
            try writer(data, fileURL)
        } catch {
            // Nothing is published: memory and disk both keep their previous contents.
            throw .writeFailed
        }
        publish(candidate)
    }

    private func publish(_ candidate: Snapshot) {
        snapshot = candidate
        counts = candidate.sessions.reduce(into: [:]) { totals, session in
            totals[session.sankalpaId, default: 0] += 1
        }
    }

    private func encode(_ candidate: Snapshot) throws -> Data {
        // No pretty-printing: this is an app data file, not something anyone reads, and the
        // formatting roughly doubles both the encode time and the file size.
        try JSONEncoder().encode(candidate)
    }

}
