import Foundation
import SankalpaCore

/// A single serialized store. Callers use it on the main actor. Changes are published in memory
/// only after an atomic disk write succeeds; unreadable files remain untouched and read-only.
public final class FileStore: SankalpaRepository, SessionRepository {
    struct Snapshot: Codable {
        var schemaVersion = 1
        var sankalpas: [Sankalpa] = []
        var sessions: [Session] = []
    }
    public let fileURL: URL
    private var snapshot = Snapshot()
    private var counts: [SankalpaId: Int] = [:]
    public private(set) var loadError: String?
    private let writer: (Data, URL) throws -> Void

    public init(fileURL: URL, writer: @escaping (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }) {
        self.fileURL = fileURL
        self.writer = writer
        reload()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Practice", isDirectory: true).appendingPathComponent("practice.json")
    }

    public func reload() {
        do {
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                snapshot = Snapshot(); counts = [:]; loadError = nil; return
            }
            let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            guard decoded.schemaVersion == 1 else {
                loadError = "This data was saved by a different app version. Update the app to open it. The original file has been preserved."
                return
            }
            try Self.validate(decoded)
            snapshot = decoded
            recount()
            loadError = nil
        } catch {
            loadError = "Your saved practice could not be opened. The original file has been preserved. Retry, or export it for recovery."
        }
    }

    public func all() -> [Sankalpa] { snapshot.sankalpas }
    public func find(_ id: SankalpaId) -> Sankalpa? { snapshot.sankalpas.first { $0.id == id } }
    public func totalCount(for id: SankalpaId) -> Int { counts[id, default: 0] }
    public func sessions(for id: SankalpaId, from: CalendarDay, until: CalendarDay) -> [Session] {
        snapshot.sessions.filter { $0.sankalpaId == id && (from...max(from, until)).contains($0.occurredAt.day) && from <= until }
    }
    public func sessions(from: CalendarDay, until: CalendarDay) -> [Session] {
        snapshot.sessions.filter { $0.occurredAt.day >= from && $0.occurredAt.day <= until }
    }
    public func save(_ sankalpa: Sankalpa) throws(PersistenceError) {
        var candidate = snapshot
        if let index = candidate.sankalpas.firstIndex(where: { $0.id == sankalpa.id }) {
            candidate.sankalpas[index] = sankalpa
        } else { candidate.sankalpas.append(sankalpa) }
        try commit(candidate)
    }
    public func save(_ session: Session) throws(PersistenceError) {
        var candidate = snapshot
        // Repeating a repository write for the same recorded fact must not duplicate it.
        guard !candidate.sessions.contains(where: { $0.id == session.id }) else { return }
        candidate.sessions.append(session)
        try commit(candidate)
    }
    public func delete(_ sessionId: SessionId) throws(PersistenceError) {
        var candidate = snapshot
        candidate.sessions.removeAll { $0.id == sessionId }
        try commit(candidate)
    }
    public func clear() throws(PersistenceError) { try commit(Snapshot()) }
    public func exportData() throws -> Data {
        // During recovery export the original bytes, never an empty replacement.
        if loadError != nil { return try Data(contentsOf: fileURL) }
        return try Self.encoder.encode(snapshot)
    }
    public struct BackupSummary: Equatable, Sendable {
        public let intentions: Int
        public let sessions: Int
    }
    public func inspectBackup(_ data: Data) throws -> BackupSummary {
        let candidate = try Self.decodeBackup(data)
        return BackupSummary(intentions: candidate.sankalpas.count, sessions: candidate.sessions.count)
    }
    public func restoreBackup(_ data: Data, recovering: Bool = false) throws {
        let candidate = try Self.decodeBackup(data)
        if recovering, let previousError = loadError {
            // Only an explicitly confirmed recovery may replace an unreadable store. Preserve
            // its exact bytes in a separate file before enabling the transactional replacement.
            let original = try Data(contentsOf: fileURL)
            let archive = fileURL.appendingPathExtension("preserved-\(UUID().uuidString).json")
            try original.write(to: archive, options: .atomic)
            loadError = nil
            do { try commit(candidate) }
            catch { loadError = previousError; throw error }
        } else {
            try commit(candidate)
        }
    }
    private static func decodeBackup(_ data: Data) throws -> Snapshot {
        let candidate = try JSONDecoder().decode(Snapshot.self, from: data)
        guard candidate.schemaVersion == 1 else { throw InvalidData.invalid }
        try validate(candidate)
        return candidate
    }
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    private func commit(_ candidate: Snapshot) throws(PersistenceError) {
        if let loadError { throw .unavailable(loadError) }
        do {
            try Self.validate(candidate)
            let data = try Self.encoder.encode(candidate)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writer(data, fileURL)
        } catch { throw .writeFailed }
        snapshot = candidate
        recount()
    }
    private func recount() {
        counts = snapshot.sessions.reduce(into: [:]) { $0[$1.sankalpaId, default: 0] += 1 }
    }
    private enum InvalidData: Error { case invalid }
    private static func validate(_ snapshot: Snapshot) throws {
        func require(_ valid: Bool) throws { if !valid { throw InvalidData.invalid } }
        func valid(_ day: CalendarDay) -> Bool {
            (1...9999).contains(day.year) && CalendarDay(year: day.year, month: day.month, day: day.day) != nil
        }
        func valid(_ moment: CalendarMoment) -> Bool {
            valid(moment.day) && (0..<86400).contains(moment.secondOfDay)
        }
        try require(Set(snapshot.sankalpas.map(\.id)).count == snapshot.sankalpas.count)
        try require(Set(snapshot.sessions.map(\.id)).count == snapshot.sessions.count)
        for item in snapshot.sankalpas {
            try require(valid(item.startDate) && valid(item.declaredAt))
            _ = try Title(item.title.value)
            _ = try TimesPerPeriod(item.commitment.timesPerPeriod.value)
            if let count = item.commitment.periodCount { _ = try PeriodCount(count.value) }
            var timeline = LifecycleTimeline()
            for transition in item.lifecycle.transitions {
                try require(valid(transition.effectiveAt) && valid(transition.recordedAt) && transition.from == timeline.current)
                try timeline.record(to: transition.to, effectiveAt: transition.effectiveAt, recordedAt: transition.recordedAt, commitmentStart: item.startDate)
            }
            try require(timeline.current == item.state)
        }
        let items = Dictionary(uniqueKeysWithValues: snapshot.sankalpas.map { ($0.id, $0) })
        for session in snapshot.sessions {
            try require(valid(session.occurredAt) && valid(session.loggedAt))
            guard let item = items[session.sankalpaId] else { throw InvalidData.invalid }
            _ = try item.logSession(id: session.id, occurredAt: session.occurredAt, now: session.loggedAt)
        }
    }
}
