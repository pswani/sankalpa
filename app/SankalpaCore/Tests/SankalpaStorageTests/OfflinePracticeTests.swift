import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

/// What the app does when the service is not there, and what happens when it comes back.
///
/// Three rules are under test, and they are easy to confuse: the practice is readable from the
/// phone's own copy; a session can still be logged and is sent later; and when the two disagree
/// the service wins — including about a session the phone already showed as logged.
@MainActor
@Suite("Offline practice")
struct OfflinePracticeTests {

    private let today = CalendarMoment(day: day(2026, 9, 10), hour: 12)

    private func loaded(
        _ transport: StubTransport, cache: PracticeCache
    ) async -> RemoteSankalpaService {
        let service = Fixture.service(transport: transport, today: today, cache: cache)
        await service.sync()
        return service
    }

    // MARK: - Reading from the phone's copy

    /// A second launch with the service away has to show the practice, not an empty app. This is
    /// the whole of requirement 2 in one test: the same cache directory, a service that never
    /// answers, and the sankalpa still there.
    @Test("A practice read once is still readable when the service is gone")
    func cachedPracticeSurvivesTheServiceGoingAway() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        _ = await loaded(Fixture.readyTransport(), cache: cache)

        let offline = StubTransport()
        offline.failEverything(with: URLError(.cannotConnectToHost))
        let relaunched = Fixture.service(transport: offline, today: today, cache: cache)

        // Before anything is asked of the network, the cache has already been read.
        #expect(relaunched.hasLoaded)
        #expect(relaunched.isShowingCachedPractice)
        #expect(relaunched.queries.summaries().first?.title == "Vipassana")

        await relaunched.sync()
        #expect(relaunched.hasLoaded)
        #expect(relaunched.queries.summaries().count == 1)
    }

    /// The cache belongs to the service it came from. Showing one computer's practice while
    /// pointed at another would be worse than showing nothing.
    @Test("A cache from a different computer is not shown")
    func cacheIsScopedToItsService() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        _ = await loaded(Fixture.readyTransport(), cache: cache)

        let offline = StubTransport()
        offline.failEverything(with: URLError(.cannotConnectToHost))
        let elsewhere = Fixture.service(
            transport: offline, today: today, cache: cache,
            at: ServiceLocation(host: "studio.local")
        )

        #expect(!elsewhere.hasLoaded)
        #expect(elsewhere.queries.summaries().isEmpty)
    }

    // MARK: - Logging while the service is away

    @Test("A session logged with the service away is accepted and counts straight away")
    func logsOfflineAndCountsImmediately() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)
        #expect(service.queries.summaries().first?.currentPeriod?.performed == 0)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        let refusal = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )

        #expect(refusal == nil)
        #expect(service.pending.count == 1)
        // The point of accepting it is that the screens move. A pending session that did not
        // count would be a confirmation with nothing behind it.
        #expect(service.queries.summaries().first?.currentPeriod?.performed == 1)
        #expect(service.queries.summaries().first?.totalSessions == 2)
    }

    /// Going offline must not become a way to record something the rules forbid. The phone has
    /// the commitment and the lifecycle, so it can apply the same rules the service would.
    @Test("A session the rules forbid is refused offline too, and is not queued")
    func offlineLoggingStillObeysTheRules() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        // Before the commitment starts on 1 September — a moment that has passed, so it is the
        // commitment rule being applied rather than the simpler "not in the future" one.
        let refusal = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 8, 20), hour: 7)
        )

        #expect(refusal == .session(.sessionBeforeCommitmentStart(startDate: day(2026, 9, 1))))
        #expect(service.pending.isEmpty)
    }

    /// Reporting "logged" over something held only in memory would lose it on the next launch,
    /// which is the one thing the outbox exists to prevent.
    @Test("A session is only reported as logged once it is on disk")
    func refusesWhenTheOutboxCannotBeWritten() async {
        let cache = PracticeCache(
            directory: Fixture.temporaryDirectory(),
            writer: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        let refusal = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )

        #expect(refusal == .storage(.writeFailed))
        #expect(service.pending.isEmpty)
    }

    @Test("Sessions waiting to be sent survive a relaunch")
    func pendingSessionsSurviveARelaunch() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        _ = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )

        let relaunched = Fixture.service(transport: transport, today: today, cache: cache)
        #expect(relaunched.pending.count == 1)
        #expect(relaunched.queries.summaries().first?.currentPeriod?.performed == 1)
    }

    // MARK: - Sending what was waiting

    /// Requirement 2.3: what exists only on the phone is replicated to the service as soon as
    /// there is a service to replicate it to.
    @Test("What was logged offline is sent as soon as the service answers")
    func pendingSessionsAreSentOnReconnect() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        _ = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )
        #expect(service.pending.count == 1)

        // The service comes back, and now knows about the session.
        let back = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: back)
        back.on("GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
                body: Fixture.sessionPageJSON(occurrences: ["2026-09-10T07:00:00"]))
        let reconnected = Fixture.service(transport: back, today: today, cache: cache)
        await reconnected.sync()

        #expect(back.requests.contains("POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"))
        #expect(reconnected.pending.isEmpty)
        // Counted once, not twice: it is the service's session now.
        #expect(reconnected.queries.summaries().first?.currentPeriod?.performed == 1)
    }

    /// Requirement 2.2, in the one place it is not automatic. The phone already told the user this
    /// session was logged; the service refuses it; the service wins and the user is told why.
    @Test("A waiting session the service refuses is dropped and reported")
    func theServiceWinsOverAWaitingSession() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        _ = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )

        // While the phone was away, the sankalpa was stopped on another device.
        let back = Fixture.readyTransport()
        back.on("POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions", status: 422,
                body: Fixture.problemJSON(
                    code: "SANKALPA_NOT_IN_PROGRESS",
                    detail: "Sankalpa was not in progress at that time"))
        let reconnected = Fixture.service(transport: back, today: today, cache: cache)
        await reconnected.sync()

        #expect(reconnected.pending.isEmpty)
        let rejections = reconnected.reconciliationNotices
        #expect(rejections.count == 1)
        #expect(rejections.first?.contains("Vipassana") == true)
        // The reason is the service's, not one rebuilt from the phone's copy. That copy still
        // says In progress — being out of date is why the session was refused — so explaining it
        // from there would produce a sentence that contradicts itself.
        #expect(rejections.first?.contains("was not in progress at that time") == true)
        #expect(rejections.first?.contains("was In progress at that time") == false)
        // The notice remains durable until the UI explicitly acknowledges it.
        #expect(reconnected.reconciliationNotices.count == 1)
        reconnected.acknowledgeReconciliationNotices()
        #expect(reconnected.reconciliationNotices.isEmpty)
    }

    /// A session that reached the service while the answer was lost comes back in the refresh.
    /// Without this it would be offered again and the practice would grow a duplicate.
    @Test("A waiting session the service already has is dropped rather than sent twice")
    func doesNotSendASessionTheServiceAlreadyHas() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.timedOut))
        _ = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )
        #expect(service.pending.count == 1)

        // The POST had in fact arrived, so the refresh returns it.
        let back = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: back)
        back.on("GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
                body: Fixture.sessionPageJSON(occurrences: ["2026-09-10T07:00:00"]))
        let reconnected = Fixture.service(transport: back, today: today, cache: cache)
        await reconnected.sync()

        #expect(reconnected.pending.isEmpty)
        #expect(reconnected.queries.summaries().first?.currentPeriod?.performed == 1)
    }

    /// One unreachable service should not empty the outbox in the attempt.
    @Test("A flush that cannot reach the service keeps everything for next time")
    func aFailedFlushKeepsTheOutbox() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        for hour in [7, 8] {
            _ = await service.logSession(
                SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
                occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: hour)
            )
        }
        #expect(service.pending.count == 2)

        await service.sync()

        #expect(service.pending.count == 2)
        #expect(service.queries.summaries().first?.currentPeriod?.performed == 2)
    }

    // MARK: - Lifecycle is not offline

    /// Only session logging and deletion work offline. A queued Pause would have to be reconciled
    /// against a service that may have moved on, and "the service wins" cannot answer that.
    @Test("A lifecycle change with the service away is refused, not queued")
    func lifecycleCommandsAreNotQueued() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        let refusal = await service.pause(SankalpaId(UUID(uuidString: Fixture.sankalpaId)!))

        #expect(refusal?.message.contains("not connected") == true)
        #expect(service.queries.summaries().first?.state == .inProgress)
    }

    /// A command that got through proves the service is reachable. Waiting for the next refresh
    /// to notice would leave a session sitting in the outbox while the app is demonstrably online.
    @Test("A command that succeeds also sends what was waiting")
    func aSuccessfulCommandFlushesTheOutbox() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = await loaded(transport, cache: cache)

        transport.failEverything(with: URLError(.notConnectedToInternet))
        _ = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )
        #expect(service.pending.count == 1)

        // The service is back, and the next thing the user does is pause — not a refresh.
        let back = Fixture.readyTransport()
        back.on("POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/pause",
                body: Fixture.sankalpaJSON(state: "PAUSED"))
        Fixture.acceptsLoggedSession(on: back)
        back.on("GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
                body: Fixture.sessionPageJSON(occurrences: ["2026-09-10T07:00:00"]))
        let reconnected = Fixture.service(transport: back, today: today, cache: cache)
        _ = await reconnected.pause(SankalpaId(UUID(uuidString: Fixture.sankalpaId)!))

        #expect(back.requests.contains("POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"))
        #expect(reconnected.pending.isEmpty)
    }
}
