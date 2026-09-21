import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

@Suite("File store")
struct StorageTests {

    /// A scratch file per test, removed afterwards.
    private func temporaryURL() -> URL {
        URL.temporaryDirectory.appendingPathComponent("sankalpa-test-\(UUID().uuidString).json")
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: dayOfMonth)!
    }

    private func moment(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int) -> CalendarMoment {
        CalendarMoment(day: day(year, month, dayOfMonth), hour: hour)
    }

    private func declared(startingOn start: CalendarDay, now: CalendarMoment) -> Sankalpa {
        try! Sankalpa.declare(
            Declaration(
                title: "Vipassana", actionType: .meditation, startDate: start,
                periodUnit: .day, timesPerPeriod: 1
            ),
            now: now
        )
    }

    // MARK: - The happy path

    @Test("A saved sankalpa survives a reload")
    func roundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileStore(fileURL: url)
        #expect(store.isNew)

        var sankalpa = declared(startingOn: day(2026, 9, 21), now: moment(2026, 9, 21, 6))
        try sankalpa.begin(BeginTiming(now: moment(2026, 9, 21, 6)))
        try store.save(sankalpa)
        let session = try sankalpa.logSession(
            occurredAt: moment(2026, 9, 21, 7), now: moment(2026, 9, 21, 8)
        )
        try store.save(session)

        let reopened = FileStore(fileURL: url)
        #expect(reopened.loadError == nil)
        #expect(!reopened.isNew)
        #expect(reopened.all().count == 1)
        #expect(reopened.totalCount(for: sankalpa.id) == 1)
    }

    // MARK: - Failed writes (P1)

    @Test("A failed write publishes nothing, in memory or on disk")
    func failedWriteChangesNothing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed one good sankalpa, then make every subsequent write fail.
        let store = FileStore(fileURL: url)
        let first = declared(startingOn: day(2026, 9, 21), now: moment(2026, 9, 21, 6))
        try store.save(first)
        let bytesBefore = try Data(contentsOf: url)

        let failing = FileStore(fileURL: url, writer: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let second = declared(startingOn: day(2026, 9, 22), now: moment(2026, 9, 22, 6))

        #expect(throws: PersistenceError.writeFailed) { try failing.save(second) }

        // Three-way: the error was raised, memory is untouched, and the file is byte-identical.
        #expect(failing.all().count == 1)
        #expect(try Data(contentsOf: url) == bytesBefore)
    }

    // MARK: - Failed loads (P1)

    @Test("An unreadable file is reported and never overwritten")
    func unreadableFileIsPreserved() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("this is not the json you are looking for".utf8)
        try corrupt.write(to: url)

        let store = FileStore(fileURL: url)
        #expect(store.loadError != nil)
        // Crucially NOT "new" — otherwise a caller seeds samples over the top of it.
        #expect(!store.isNew)

        let sankalpa = declared(startingOn: day(2026, 9, 21), now: moment(2026, 9, 21, 6))
        #expect(throws: PersistenceError.self) { try store.save(sankalpa) }
        #expect(throws: PersistenceError.self) { try store.clear() }

        // The original bytes are still there.
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test("A store written by a newer version is refused rather than replaced")
    func newerSchemaIsRefused() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let future = Data(#"{"schemaVersion":2,"sankalpas":[],"sessions":[]}"#.utf8)
        try future.write(to: url)

        let store = FileStore(fileURL: url)
        #expect(store.loadError != nil)
        #expect(!store.isNew)
        #expect(throws: PersistenceError.self) { try store.clear() }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("A missing file is a fresh start, not a failure")
    func missingFileIsNew() {
        let store = FileStore(fileURL: temporaryURL())
        #expect(store.loadError == nil)
        #expect(store.isNew)
    }

    // MARK: - Range-bounded reads

    @Test("Session reads are day-range bounded and refuse an inverted range")
    func rangeBoundedReads() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileStore(fileURL: url)
        var sankalpa = declared(startingOn: day(2026, 9, 1), now: moment(2026, 9, 1, 6))
        try sankalpa.begin(BeginTiming(now: moment(2026, 9, 1, 6)))
        try store.save(sankalpa)
        for dayOfMonth in 1...10 {
            try store.save(
                try sankalpa.logSession(
                    occurredAt: moment(2026, 9, dayOfMonth, 7), now: moment(2026, 9, 30, 9)
                )
            )
        }

        #expect(store.sessions(for: sankalpa.id, from: day(2026, 9, 3), until: day(2026, 9, 5)).count == 3)
        #expect(store.sessions(for: sankalpa.id, from: day(2026, 9, 5), until: day(2026, 9, 3)).isEmpty)
        #expect(store.sessions(from: day(2026, 9, 1), until: day(2026, 9, 10)).count == 10)
        #expect(store.totalCount(for: sankalpa.id) == 10)
    }
}
