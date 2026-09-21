import Foundation

/// Coordinates the use cases from 05-application-layer: it loads, maps input into domain values,
/// invokes domain behaviour, saves, and returns success or a domain error.
///
/// It holds no lifecycle or commitment rules of its own. One type rather than seven single-method
/// classes keeps the use-case names visible without the ceremony a local single-user app cannot
/// justify; each method below is exactly one use case.
public final class SankalpaApplicationService {
    private let sankalpas: SankalpaRepository
    private let sessions: SessionRepository
    private let clock: SankalpaClock

    public init(
        sankalpas: SankalpaRepository,
        sessions: SessionRepository,
        clock: SankalpaClock
    ) {
        self.sankalpas = sankalpas
        self.sessions = sessions
        self.clock = clock
    }

    public func now() -> CalendarMoment { clock.now() }
    public func today() -> CalendarDay { clock.today() }

    // MARK: - Repository access for the query extension

    func allSankalpas() -> [Sankalpa] { sankalpas.all() }

    func findSankalpa(_ id: SankalpaId) -> Sankalpa? { sankalpas.find(id) }

    func sessionsInRange(
        _ id: SankalpaId,
        from: CalendarDay,
        until: CalendarDay
    ) -> [Session] {
        guard from <= until else { return [] }
        return sessions.sessions(for: id, from: from, until: until)
    }

    func sessionsInRange(from: CalendarDay, until: CalendarDay) -> [Session] {
        guard from <= until else { return [] }
        return sessions.sessions(from: from, until: until)
    }

    /// `GetSankalpaDetail` reports a lifetime count, which is a single stored aggregate rather than
    /// a history scan.
    public func totalSessionCount(_ id: SankalpaId) -> Int {
        sessions.totalCount(for: id)
    }

    // MARK: - Commands

    /// `DeclareSankalpa` — creates a sankalpa in Not started.
    @discardableResult
    public func declareSankalpa(
        _ declaration: Declaration
    ) throws(SankalpaCommandError) -> Sankalpa {
        let sankalpa: Sankalpa
        do {
            sankalpa = try Sankalpa.declare(declaration, now: clock.now())
        } catch {
            throw .declaration(error)
        }
        do {
            try sankalpas.save(sankalpa)
        } catch {
            throw .storage(error)
        }
        return sankalpa
    }

    /// `BeginSankalpa` — the one command that accepts an effective time in the past. `recordedAt`
    /// is never client supplied.
    public func beginSankalpa(
        _ id: SankalpaId,
        effectiveAt: CalendarMoment? = nil
    ) throws(SankalpaCommandError) {
        try mutate(id) { sankalpa, now throws(LifecycleTransitionError) in
            try sankalpa.begin(BeginTiming(effectiveAt: effectiveAt ?? now, recordedAt: now))
        }
    }

    /// `PauseSankalpa`
    public func pauseSankalpa(_ id: SankalpaId) throws(SankalpaCommandError) {
        try mutate(id) { sankalpa, now throws(LifecycleTransitionError) in
            try sankalpa.pause(now: now)
        }
    }

    /// `ResumeSankalpa`
    public func resumeSankalpa(_ id: SankalpaId) throws(SankalpaCommandError) {
        try mutate(id) { sankalpa, now throws(LifecycleTransitionError) in
            try sankalpa.resume(now: now)
        }
    }

    /// `CompleteSankalpa` — the user, not the system, says which outcome it was.
    public func completeSankalpa(
        _ id: SankalpaId,
        outcome: CompletionOutcome
    ) throws(SankalpaCommandError) {
        try mutate(id) { sankalpa, now throws(LifecycleTransitionError) in
            try sankalpa.complete(outcome, now: now)
        }
    }

    /// `StopSankalpa`
    public func stopSankalpa(_ id: SankalpaId) throws(SankalpaCommandError) {
        try mutate(id) { sankalpa, now throws(LifecycleTransitionError) in
            try sankalpa.stop(now: now)
        }
    }

    /// `LogSession` — records a past performed session. The aggregate decides whether it is
    /// eligible; this method only supplies the clock and persists the result.
    @discardableResult
    public func logSession(
        _ id: SankalpaId,
        occurredAt: CalendarMoment
    ) throws(SankalpaCommandError) -> Session {
        guard let sankalpa = sankalpas.find(id) else { throw .sankalpaNotFound(id) }
        let session: Session
        do {
            session = try sankalpa.logSession(occurredAt: occurredAt, now: clock.now())
        } catch {
            throw .session(error)
        }
        do {
            try sessions.save(session)
        } catch {
            throw .storage(error)
        }
        return session
    }

    /// Takes back a session that was just logged.
    ///
    /// A logged session is a recorded past fact, and the requirements have no edit or delete use
    /// case for one. Undoing the tap you just made is a different thing from amending history, so
    /// this is deliberately narrow *by how it is offered*: the UI only ever passes the id it just
    /// received from `logSession`, and only while that confirmation is still on screen. Nothing
    /// here enforces which session an id names, so this is not an editing back door to build on.
    ///
    /// An id that names nothing is reported rather than silently succeeding, because "Session
    /// removed" over a session that is still there is worse than an error.
    public func undoLoggedSession(_ sessionId: SessionId) throws(SankalpaCommandError) {
        let removed: Bool
        do {
            removed = try sessions.delete(sessionId)
        } catch {
            throw .storage(error)
        }
        guard removed else { throw .sessionNotFound(sessionId) }
    }

    private func mutate(
        _ id: SankalpaId,
        _ change: (inout Sankalpa, CalendarMoment) throws(LifecycleTransitionError) -> Void
    ) throws(SankalpaCommandError) {
        guard var sankalpa = sankalpas.find(id) else { throw .sankalpaNotFound(id) }
        do {
            try change(&sankalpa, clock.now())
        } catch {
            throw .lifecycle(error)
        }
        do {
            try sankalpas.save(sankalpa)
        } catch {
            throw .storage(error)
        }
    }
}
