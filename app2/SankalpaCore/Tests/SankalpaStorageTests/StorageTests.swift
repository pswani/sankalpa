import Foundation
import Testing
import SankalpaCore
@testable import SankalpaStorage

private struct Clock: SankalpaClock {
    var time = CalendarMoment(day: CalendarDay(year: 2026, month: 9, day: 21)!, hour: 12)
    func now() -> CalendarMoment { time }
}
private func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("practice.json") }
private func declaration(_ now: CalendarMoment, start: CalendarDay? = nil) -> Declaration {
    Declaration(title: "Morning practice", actionType: .meditation, startDate: start ?? now.day, periodUnit: .day, timesPerPeriod: 2)
}
@Suite("Durable storage") struct StorageTests {
    @Test func emptyIsNotSeeded() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileStore(fileURL: url)
        try store.clear()
        #expect(FileStore(fileURL: url).all().isEmpty)
    }
    @Test(arguments: ["broken JSON", "{\"schemaVersion\":2,\"sankalpas\":[],\"sessions\":[]}"])
    func unreadableDataIsPreserved(content: String) throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(content.utf8); try original.write(to: url)
        let store = FileStore(fileURL: url)
        #expect(store.loadError != nil)
        #expect(throws: PersistenceError.self) { try store.clear() }
        #expect(try Data(contentsOf: url) == original)
        #expect(try store.exportData() == original)
    }
    @Test func failedWriteDoesNotPublishMutation() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let initial = FileStore(fileURL: url)
        let now = Clock().now()
        let item = try Sankalpa.declare(declaration(now), now: now)
        try initial.save(item)
        let before = try Data(contentsOf: url)
        let failing = FileStore(fileURL: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(throws: PersistenceError.writeFailed) { try failing.clear() }
        #expect(failing.all().count == 1)
        #expect(try Data(contentsOf: url) == before)
    }
    @Test func historyRoundTripsAndBackfillSurvivesStop() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileStore(fileURL: url), clock = Clock()
        let service = SankalpaApplicationService(sankalpas: store, sessions: store, clock: clock)
        let item = try service.declareSankalpa(declaration(clock.now()))
        try service.beginSankalpa(item.id, effectiveAt: .startOfDay(clock.today()))
        try service.stopSankalpa(item.id)
        let session = try service.logSession(item.id, occurredAt: CalendarMoment(day: clock.today(), hour: 7))
        let reloaded = FileStore(fileURL: url)
        #expect(reloaded.loadError == nil)
        #expect(reloaded.find(item.id)?.state == .stopped)
        #expect(reloaded.find(item.id)?.lifecycle.transitions.count == 2)
        #expect(reloaded.sessions(for: item.id, from: clock.today(), until: clock.today()) == [session])
        try reloaded.save(session)
        #expect(reloaded.totalCount(for: item.id) == 1)
    }
    @Test func malformedDomainDataIsBlocked() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileStore(fileURL: url), now = Clock().now()
        try store.save(Sankalpa.declare(declaration(now), now: now))
        var text = String(data: try store.exportData(), encoding: .utf8)!
        text = text.replacingOccurrences(of: "\"month\" : 9", with: "\"month\" : 99")
        try Data(text.utf8).write(to: url)
        #expect(FileStore(fileURL: url).loadError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }
    @Test func momentRoundTripPreservesSeconds() {
        let moment = CalendarMoment(day: Clock().today(), hour: 12, minute: 34, second: 56)
        #expect(AppTime.moment(from: AppTime.date(from: moment)) == moment)
    }
}
@Suite("Application model") @MainActor struct ModelTests {
    @Test func failedSaveHasNoSuccessNotice() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = PracticeModel(store: FileStore(fileURL: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }), clock: Clock())
        #expect(model.declare(declaration(model.now())) == nil)
        #expect(model.alert != nil)
        #expect(model.notice == nil)
        #expect(model.summaries.isEmpty)
    }
    @Test func latestEligibleTimeEndsBeforePause() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock(), store = FileStore(fileURL: url)
        var item = try Sankalpa.declare(declaration(clock.now()), now: clock.now())
        try item.begin(BeginTiming(now: .startOfDay(clock.today())))
        try item.pause(now: CalendarMoment(day: clock.today(), hour: 10))
        try store.save(item)
        let model = PracticeModel(store: store, clock: clock)
        let eligible = try #require(model.latestEligibleMoment(item))
        #expect(eligible.hour == 9 && eligible.minute == 59 && eligible.secondOfDay % 60 == 59)
        #expect(model.log(item.id, at: eligible) == nil)
    }
}

@Suite("Backups and history") struct BackupTests {
    @Test func validBackupRestoresAndInvalidBackupCannotReplaceData() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileStore(fileURL: url), clock = Clock()
        let service = SankalpaApplicationService(sankalpas: store, sessions: store, clock: clock)
        let item = try service.declareSankalpa(declaration(clock.now()))
        try service.beginSankalpa(item.id, effectiveAt: .startOfDay(clock.today()))
        _ = try service.logSession(item.id, occurredAt: clock.now())
        let backup = try store.exportData()
        #expect(try store.inspectBackup(backup).sessions == 1)
        try store.clear()
        try store.restoreBackup(backup)
        #expect(store.totalCount(for: item.id) == 1)
        #expect(FileStore(fileURL: url).find(item.id)?.state == .inProgress)
        #expect(throws: (any Error).self) { try store.restoreBackup(Data("{}".utf8)) }
        #expect(try store.exportData() == backup)
    }
    @Test func historyCanBeReadBeyondFormerLimits() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock(), store = FileStore(fileURL: url)
        let start = clock.today().addingDays(-600)
        let initial = CalendarMoment.startOfDay(start)
        var item = try Sankalpa.declare(declaration(initial), now: initial)
        try item.begin(BeginTiming(now: initial))
        try store.save(item)
        let session = try item.logSession(occurredAt: CalendarMoment(day: start, hour: 7), now: clock.now())
        try store.save(session)
        let service = SankalpaApplicationService(sankalpas: store, sessions: store, clock: clock)
        var closed = 0
        for offset in stride(from: 0, to: 600, by: 30) {
            let page = service.periodOutcomes(item.id, from: start.addingDays(offset), until: start.addingDays(offset + 29))
            #expect(page.count == 30)
            closed += page.filter { $0.standing != .open }.count
        }
        #expect(closed == 600)
        #expect(service.sessions(item.id, from: start.monthStart, until: start.monthStart.addingMonths(1).addingDays(-1)) == [session])
    }
}

@Suite("Explicit recovery") struct RecoveryTests {
    @Test func recoveryPreservesDamagedOriginalBeforeRestoring() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let healthy = FileStore(fileURL: url), now = Clock().now()
        try healthy.save(Sankalpa.declare(declaration(now), now: now))
        let backup = try healthy.exportData(), original = Data("damaged original".utf8)
        try original.write(to: url)
        let damaged = FileStore(fileURL: url)
        #expect(damaged.loadError != nil)
        #expect(throws: (any Error).self) { try damaged.restoreBackup(backup) }
        try damaged.restoreBackup(backup, recovering: true)
        #expect(damaged.loadError == nil)
        #expect(damaged.all().count == 1)
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let preserved = try #require(files.first { $0.lastPathComponent.contains("preserved-") })
        #expect(try Data(contentsOf: preserved) == original)
    }
    @Test func failedRecoveryStillBlocksWritesAndPreservesOriginal() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("damaged".utf8); try original.write(to: url)
        let store = FileStore(fileURL: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let backup = Data("{\"schemaVersion\":1,\"sankalpas\":[],\"sessions\":[]}".utf8)
        #expect(throws: (any Error).self) { try store.restoreBackup(backup, recovering: true) }
        #expect(store.loadError != nil)
        #expect(try Data(contentsOf: url) == original)
    }
}
