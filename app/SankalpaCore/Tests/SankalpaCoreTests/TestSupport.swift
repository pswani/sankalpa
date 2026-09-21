import Foundation
@testable import SankalpaCore

// MARK: - Convenience constructors

func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
    guard let value = CalendarDay(year: year, month: month, day: dayOfMonth) else {
        fatalError("invalid test date \(year)-\(month)-\(dayOfMonth)")
    }
    return value
}

func moment(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int = 9, _ minute: Int = 0) -> CalendarMoment {
    CalendarMoment(day: day(year, month, dayOfMonth), hour: hour, minute: minute)
}

func times(_ value: Int) -> TimesPerPeriod { try! TimesPerPeriod(value) }
func periods(_ value: Int) -> PeriodCount { try! PeriodCount(value) }

// MARK: - Test doubles

/// A clock the tests move by hand, which is the whole reason time is a port.
final class FixedClock: SankalpaClock {
    var current: CalendarMoment

    init(_ current: CalendarMoment) { self.current = current }

    func now() -> CalendarMoment { current }

    func advance(toDay newDay: CalendarDay, hour: Int = 9) {
        current = CalendarMoment(day: newDay, hour: hour, minute: 0)
    }

    func advance(days count: Int) {
        current = CalendarMoment(day: current.day.addingDays(count), secondOfDay: current.secondOfDay)
    }
}

final class InMemorySankalpaRepository: SankalpaRepository {
    private var storage: [SankalpaId: Sankalpa] = [:]
    private var order: [SankalpaId] = []

    func all() -> [Sankalpa] { order.compactMap { storage[$0] } }

    func find(_ id: SankalpaId) -> Sankalpa? { storage[id] }

    /// Set to make every write fail, so a caller's handling of a storage failure can be tested.
    var failWrites = false

    func save(_ sankalpa: Sankalpa) throws(PersistenceError) {
        if failWrites { throw .writeFailed }
        if storage[sankalpa.id] == nil { order.append(sankalpa.id) }
        storage[sankalpa.id] = sankalpa
    }
}

final class InMemorySessionRepository: SessionRepository {
    private(set) var storage: [Session] = []

    var failWrites = false

    func save(_ session: Session) throws(PersistenceError) {
        if failWrites { throw .writeFailed }
        storage.append(session)
    }

    @discardableResult
    func delete(_ sessionId: SessionId) throws(PersistenceError) -> Bool {
        if failWrites { throw .writeFailed }
        guard storage.contains(where: { $0.id == sessionId }) else { return false }
        storage.removeAll { $0.id == sessionId }
        return true
    }

    func sessions(for sankalpaId: SankalpaId, from: CalendarDay, until: CalendarDay) -> [Session] {
        storage.filter {
            $0.sankalpaId == sankalpaId && $0.occurredAt.day >= from && $0.occurredAt.day <= until
        }
    }

    func sessions(from: CalendarDay, until: CalendarDay) -> [Session] {
        storage.filter { $0.occurredAt.day >= from && $0.occurredAt.day <= until }
    }

    func totalCount(for sankalpaId: SankalpaId) -> Int {
        storage.count { $0.sankalpaId == sankalpaId }
    }
}

/// A fully wired application service over in-memory adapters.
struct TestEnvironment {
    let clock: FixedClock
    let sankalpas = InMemorySankalpaRepository()
    let sessions = InMemorySessionRepository()
    let service: SankalpaApplicationService

    init(today: CalendarMoment) {
        let clock = FixedClock(today)
        self.clock = clock
        self.service = SankalpaApplicationService(
            sankalpas: sankalpas,
            sessions: sessions,
            clock: clock
        )
    }
}

extension Sankalpa {
    /// A sankalpa built directly, bypassing the application service, for domain-level tests.
    static func testDeclared(
        startDate: CalendarDay,
        unit: PeriodUnit,
        timesPerPeriod: Int,
        periodCount: Int? = nil,
        now: CalendarMoment
    ) -> Sankalpa {
        try! Sankalpa.declare(
            Declaration(
                title: "Test sankalpa",
                actionType: .meditation,
                startDate: startDate,
                periodUnit: unit,
                timesPerPeriod: timesPerPeriod,
                periodCount: periodCount
            ),
            now: now
        )
    }
}
