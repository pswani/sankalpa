import Foundation
import Observation
import SankalpaCore

public struct Notice: Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let canUndo: Bool
}

@MainActor @Observable
public final class PracticeModel {
    private let store: FileStore
    private let service: SankalpaApplicationService
    public private(set) var summaries: [SankalpaSummary] = []
    public private(set) var today: CalendarDay
    public private(set) var revision = 0
    public private(set) var storageProblem: String?
    public var alert: String?
    public var notice: Notice?
    private var undoable: (SessionId, Date)?

    public init(store: FileStore, clock: SankalpaClock = SystemClock()) {
        self.store = store
        service = SankalpaApplicationService(sankalpas: store, sessions: store, clock: clock)
        today = clock.today()
        refresh()
    }
    public func refresh() {
        today = service.today()
        storageProblem = store.loadError
        summaries = service.summaries()
        revision += 1
    }
    public func retryLoading() { store.reload(); refresh() }
    public func now() -> CalendarMoment { service.now() }
    public func summary(_ id: SankalpaId) -> SankalpaSummary? { summaries.first { $0.id == id } }
    public var active: [SankalpaSummary] { summaries.filter { !$0.state.isTerminal } }
    public var oldestDay: CalendarDay { min(today, summaries.map(\.commitment.startDate).min() ?? today) }
    public func sessions(_ id: SankalpaId, from: CalendarDay, until: CalendarDay) -> [Session] {
        _ = revision
        return service.sessions(id, from: from, until: until)
    }
    public func journal(from: CalendarDay, until: CalendarDay) -> [JournalEntry] {
        _ = revision
        return service.journal(from: from, until: until)
    }
    public func outcomes(_ id: SankalpaId, from: CalendarDay, until: CalendarDay) -> [PeriodOutcome] {
        _ = revision
        return service.periodOutcomes(id, from: from, until: until)
    }
    public func recentOutcomes(_ id: SankalpaId) -> [PeriodOutcome] {
        _ = revision
        return service.recentPeriodOutcomes(id, limit: 14)
    }
    public func history(_ id: SankalpaId) -> [LifecycleTransition] {
        _ = revision
        return service.lifecycleHistory(id)
    }
    public func performed(_ id: SankalpaId, in window: PeriodWindow) -> Int {
        _ = revision
        return service.performedCount(id, in: window)
    }
    /// The newest eligible timestamp, even for a paused, ended, or terminal practice.
    public func latestEligibleMoment(_ item: Sankalpa) -> CalendarMoment? {
        let now = now()
        var upper = now
        if let end = item.endDate { upper = min(upper, .endOfDay(end)) }
        let transitions = item.lifecycle.transitions
        for index in transitions.indices.reversed() where transitions[index].to == .inProgress {
            let lower = transitions[index].effectiveAt
            var end = upper
            if index + 1 < transitions.count {
                let boundary = transitions[index + 1].effectiveAt
                end = min(end, boundary.secondOfDay == 0
                    ? .endOfDay(boundary.day.addingDays(-1))
                    : CalendarMoment(day: boundary.day, secondOfDay: boundary.secondOfDay - 1))
            }
            if end >= lower { return end }
        }
        return nil
    }
    @discardableResult public func declare(_ declaration: Declaration) -> SankalpaId? {
        do {
            let item = try service.declareSankalpa(declaration)
            success("Intent declared")
            return item.id
        } catch { alert = error.message; return nil }
    }
    /// Inline error, if any; callers must never discard a failed command.
    public func log(_ id: SankalpaId, at moment: CalendarMoment) -> String? {
        do {
            let session = try service.logSession(id, occurredAt: moment)
            success("Session recorded")
            undoable = (session.id, Date().addingTimeInterval(8))
            notice = Notice(text: "Session recorded", canUndo: true)
            return nil
        } catch { return error.message }
    }
    public func logNow(_ id: SankalpaId) {
        if let error = log(id, at: now()) { alert = error }
    }
    @discardableResult public func begin(_ id: SankalpaId, at moment: CalendarMoment) -> Bool {
        execute("Practice begun") { try service.beginSankalpa(id, effectiveAt: moment) }
    }
    public func pause(_ id: SankalpaId) { _ = execute("Practice paused") { try service.pauseSankalpa(id) } }
    public func resume(_ id: SankalpaId) { _ = execute("Practice resumed") { try service.resumeSankalpa(id) } }
    public func stop(_ id: SankalpaId) { _ = execute("Practice stopped") { try service.stopSankalpa(id) } }
    public func complete(_ id: SankalpaId, outcome: CompletionOutcome) {
        _ = execute("Practice completed") { try service.completeSankalpa(id, outcome: outcome) }
    }
    public func undo() {
        guard let (id, deadline) = undoable, Date() <= deadline else { dismissNotice(); return }
        _ = execute("Session removed") { try service.undoLoggedSession(id) }
    }
    public func dismissNotice() { notice = nil; undoable = nil }
    public func clearAll() {
        do { try store.clear(); success("All practice data cleared") }
        catch { alert = error.message }
    }
    public func exportData() throws -> Data { try store.exportData() }
    public func inspectBackup(_ data: Data) throws -> FileStore.BackupSummary { try store.inspectBackup(data) }
    public func restoreBackup(_ data: Data, recovering: Bool = false) -> String? {
        do { try store.restoreBackup(data, recovering: recovering); success("Backup restored"); return nil }
        catch let error as PersistenceError { return error.message }
        catch { return "This file is not a valid Sankalpa 2 backup. Your current data is unchanged." }
    }
    private func execute(_ message: String, command: () throws -> Void) -> Bool {
        do { try command(); success(message); return true }
        catch let error as SankalpaCommandError { alert = error.message; return false }
        catch { alert = "The change could not be saved. Please try again."; return false }
    }
    private func success(_ message: String) {
        undoable = nil
        refresh()
        notice = Notice(text: message, canUndo: false)
    }
}
