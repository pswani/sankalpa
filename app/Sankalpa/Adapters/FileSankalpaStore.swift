import Foundation
import OSLog
import SankalpaCore

/// Persistence for a single-user local app: one JSON file in Application Support.
///
/// It implements both repository ports. The stored file carries a schema version so the shape can
/// change later without guessing at what an old file meant. There are no event, outbox, projection
/// or ownership structures, because nothing in the requirements needs them.
final class FileSankalpaStore: SankalpaRepository, SessionRepository {
    private static let logger = Logger(subsystem: "com.sankalpa.app", category: "store")
    private static let currentSchemaVersion = 1

    private struct StoreFile: Codable {
        var schemaVersion: Int
        var sankalpas: [Sankalpa]
        var sessions: [Session]
    }

    private let fileURL: URL
    private var sankalpasById: [SankalpaId: Sankalpa] = [:]
    /// Declaration order, so the list has a stable tiebreak.
    private var sankalpaOrder: [SankalpaId] = []
    private var sessionStorage: [Session] = []
    /// Kept alongside the sessions so a lifetime count never scans history.
    private var sessionCounts: [SankalpaId: Int] = [:]

    var isEmpty: Bool { sankalpaOrder.isEmpty }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sankalpa-store.json")
    }

    // MARK: - SankalpaRepository

    func all() -> [Sankalpa] { sankalpaOrder.compactMap { sankalpasById[$0] } }

    func find(_ id: SankalpaId) -> Sankalpa? { sankalpasById[id] }

    func save(_ sankalpa: Sankalpa) {
        if sankalpasById[sankalpa.id] == nil { sankalpaOrder.append(sankalpa.id) }
        sankalpasById[sankalpa.id] = sankalpa
        persist()
    }

    // MARK: - SessionRepository

    func save(_ session: Session) {
        sessionStorage.append(session)
        sessionCounts[session.sankalpaId, default: 0] += 1
        persist()
    }

    func delete(_ sessionId: SessionId) {
        guard let index = sessionStorage.firstIndex(where: { $0.id == sessionId }) else { return }
        let removed = sessionStorage.remove(at: index)
        sessionCounts[removed.sankalpaId, default: 1] -= 1
        persist()
    }

    func sessions(for sankalpaId: SankalpaId, from: CalendarDay, until: CalendarDay) -> [Session] {
        sessionStorage.filter {
            $0.sankalpaId == sankalpaId && $0.occurredAt.day >= from && $0.occurredAt.day <= until
        }
    }

    func sessions(from: CalendarDay, until: CalendarDay) -> [Session] {
        sessionStorage.filter { $0.occurredAt.day >= from && $0.occurredAt.day <= until }
    }

    func totalCount(for sankalpaId: SankalpaId) -> Int { sessionCounts[sankalpaId] ?? 0 }

    // MARK: - Bulk operations

    /// Replaces everything, used to seed the first launch and to clear the sample data.
    func replaceAll(sankalpas: [Sankalpa], sessions: [Session]) {
        sankalpaOrder = sankalpas.map(\.id)
        sankalpasById = Dictionary(uniqueKeysWithValues: sankalpas.map { ($0.id, $0) })
        sessionStorage = sessions
        sessionCounts = sessions.reduce(into: [:]) { counts, session in
            counts[session.sankalpaId, default: 0] += 1
        }
        persist()
    }

    // MARK: - File I/O

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let file = try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
            guard file.schemaVersion <= Self.currentSchemaVersion else {
                Self.logger.error("Store written by a newer version; starting empty to avoid data loss.")
                return
            }
            replaceInMemory(sankalpas: file.sankalpas, sessions: file.sessions)
        } catch {
            // A local store that cannot be read is logged and left alone rather than overwritten,
            // so the file is still there to recover from.
            Self.logger.error("Could not read the store: \(error.localizedDescription)")
        }
    }

    private func replaceInMemory(sankalpas: [Sankalpa], sessions: [Session]) {
        sankalpaOrder = sankalpas.map(\.id)
        sankalpasById = Dictionary(uniqueKeysWithValues: sankalpas.map { ($0.id, $0) })
        sessionStorage = sessions
        sessionCounts = sessions.reduce(into: [:]) { counts, session in
            counts[session.sankalpaId, default: 0] += 1
        }
    }

    private func persist() {
        let file = StoreFile(
            schemaVersion: Self.currentSchemaVersion,
            sankalpas: all(),
            sessions: sessionStorage
        )
        do {
            // No pretty-printing: this is an app data file, not something anyone reads, and the
            // formatting roughly doubles both the encode time and the file size.
            try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Could not write the store: \(error.localizedDescription)")
        }
    }
}
