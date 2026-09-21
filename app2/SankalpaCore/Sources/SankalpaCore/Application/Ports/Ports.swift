import Foundation

/// Time is a port so the period arithmetic can be tested at any date (DD-9).
public protocol SankalpaClock {
    func now() -> CalendarMoment
    func today() -> CalendarDay
}

extension SankalpaClock {
    public func today() -> CalendarDay { now().day }
}

/// Persistence for the aggregate.
public protocol SankalpaRepository {
    func all() -> [Sankalpa]
    func find(_ id: SankalpaId) -> Sankalpa?
    func save(_ sankalpa: Sankalpa) throws(PersistenceError)
}

/// Sessions are stored separately from the aggregate so history can grow unbounded (DD-5). Every
/// read is day-range bounded, which is what keeps an indefinite daily commitment cheap (DD-17).
public protocol SessionRepository {
    func save(_ session: Session) throws(PersistenceError)
    /// Removes one session. This exists only so the user can take back a log they just made; it is
    /// not a general session-editing capability (09-open-questions Q3).
    func delete(_ sessionId: SessionId) throws(PersistenceError)
    func sessions(for sankalpaId: SankalpaId, from: CalendarDay, until: CalendarDay) -> [Session]
    func sessions(from: CalendarDay, until: CalendarDay) -> [Session]
    func totalCount(for sankalpaId: SankalpaId) -> Int
}

/// Persistence errors cross the application boundary; a command succeeds only once it is saved.
public enum PersistenceError: Error, Equatable, Sendable {
    case unavailable(String)
    case writeFailed
    public var message: String {
        switch self {
        case .unavailable(let reason): return reason
        case .writeFailed: return "Your change could not be saved. Your previous data is safe. Free up storage or try again."
        }
    }
}
