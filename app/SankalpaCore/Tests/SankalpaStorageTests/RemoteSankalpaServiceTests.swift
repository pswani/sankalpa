import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

/// The seam between the app and the service: what a refresh actually reads, what a command sends,
/// and what the app is left holding when the service says no or says nothing at all.
@MainActor
@Suite("Remote service")
struct RemoteSankalpaServiceTests {

    // MARK: - Refreshing

    /// The list endpoint returns declarations only. The derived screens need the transitions and
    /// the sessions too, so a refresh that stopped reading either would leave every period looking
    /// empty while the list still looked right.
    @Test("A refresh reads the declarations, the audit trail and the session history")
    func refreshReadsEverythingTheScreensNeed() async {
        let transport = Fixture.readyTransport()
        let service = Fixture.service(transport: transport)

        await service.refresh()

        #expect(service.hasLoaded)
        #expect(service.refreshFailure == nil)
        #expect(transport.requests.contains("GET /api/v1/sankalpas"))
        #expect(transport.requests.contains(
            "GET /api/v1/sankalpas/\(Fixture.sankalpaId)/lifecycle-history"
        ))
        #expect(transport.requests.contains { $0.hasPrefix(
            "GET /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ) })
    }

    @Test("The summary a refresh produces carries the current period and the session count")
    func refreshBuildsSummaries() async {
        let transport = Fixture.readyTransport()
        // Two sessions on the tenth, against a commitment of two a day, satisfies today.
        transport.on("GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
                     body: Fixture.sessionPageJSON(occurrences: [
                        "2026-09-10T07:00:00", "2026-09-10T19:00:00"
                     ]))
        let service = Fixture.service(transport: transport)

        await service.refresh()
        let summaries = service.queries.summaries()

        #expect(summaries.count == 1)
        #expect(summaries.first?.title == "Vipassana")
        #expect(summaries.first?.totalSessions == 2)
        #expect(summaries.first?.currentPeriod?.performed == 2)
        #expect(summaries.first?.currentPeriod?.isSatisfied == true)
    }

    /// The period screens are computed on the device from server-sourced facts, because the list
    /// endpoint does not carry them. This is the check that the arithmetic still lands on
    /// server data.
    @Test("Closed periods are judged from the sessions the service returned")
    func derivesPeriodOutcomesFromServerData() async {
        let transport = Fixture.readyTransport()
        transport.on("GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
                     body: Fixture.sessionPageJSON(occurrences: [
                        "2026-09-01T07:00:00", "2026-09-01T19:00:00",  // satisfied
                        "2026-09-02T07:00:00"                          // one short
                     ]))
        let service = Fixture.service(transport: transport)

        await service.refresh()
        let outcomes = service.queries.periodOutcomes(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            from: day(2026, 9, 1), until: day(2026, 9, 2)
        )

        #expect(outcomes.map(\.standing) == [.satisfied, .unsatisfied])
        #expect(outcomes.last?.missed == 1)
    }

    @Test("The service's ordering survives a refresh that fans out concurrently")
    func keepsServiceOrdering() async {
        let second = "33333333-3333-3333-3333-333333333333"
        let transport = StubTransport()
        transport.on("GET", "/api/v1/sankalpas", body: """
            [\(Fixture.sankalpaJSON(title: "First")),
             \(Fixture.sankalpaJSON(id: second, title: "Second"))]
            """)
        for id in [Fixture.sankalpaId, second] {
            transport.on("GET", "/api/v1/sankalpas/\(id)/lifecycle-history",
                         body: Fixture.transitionsJSON())
            transport.on("GET", "/api/v1/sankalpas/\(id)/sessions",
                         body: Fixture.sessionPageJSON(occurrences: []))
        }
        let service = Fixture.service(transport: transport)

        await service.refresh()

        #expect(service.queries.allSankalpas().map(\.title.value) == ["First", "Second"])
    }

    // MARK: - Failing to reach the service

    @Test("A first refusal to connect leaves nothing loaded and says why")
    func firstConnectionFailure() async {
        let transport = StubTransport()
        transport.failEverything(with: URLError(.cannotConnectToHost))
        let service = Fixture.service(transport: transport)

        await service.refresh()

        #expect(!service.hasLoaded)
        #expect(service.refreshFailure?.contains("not answering") == true)
    }

    /// A stale practice is worth more than a blank screen, so a later failure must not throw away
    /// what is already on it.
    @Test("A later failure keeps the snapshot that is already loaded")
    func laterFailureKeepsTheSnapshot() async {
        let transport = Fixture.readyTransport()
        let service = Fixture.service(transport: transport)
        await service.refresh()
        #expect(service.queries.summaries().count == 1)

        transport.failEverything(with: URLError(.timedOut))
        await service.refresh()

        #expect(service.hasLoaded)
        #expect(service.refreshFailure != nil)
        #expect(service.queries.summaries().count == 1)
    }

    /// A field this version cannot read is reported rather than absorbed: half a sankalpa on
    /// screen would be worse than saying the two ends disagree.
    @Test("Data this version cannot read is reported as a refresh failure")
    func unreadableDataIsReported() async {
        let transport = Fixture.readyTransport()
        transport.on("GET", "/api/v1/sankalpas",
                     body: "[\(Fixture.sankalpaJSON(periodUnit: "FORTNIGHT"))]")
        let service = Fixture.service(transport: transport)

        await service.refresh()

        #expect(!service.hasLoaded)
        #expect(service.refreshFailure?.contains("does not understand") == true)
    }

    // MARK: - Commands

    @Test("Logging a session posts it and then re-reads the practice")
    func logSessionPostsAndRefreshes() async {
        let transport = Fixture.readyTransport()
        transport.on("POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions", status: 201, body: """
            {"id":"\(Fixture.sessionId)","sankalpaId":"\(Fixture.sankalpaId)",
             "occurredAt":"2026-09-10T07:00:00","loggedAt":"2026-09-10T12:00:00"}
            """)
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let refusal = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 7)
        )

        #expect(refusal == nil)
        #expect(transport.requests.contains("POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"))
        // The command is followed by a re-read, which is what puts the new session on screen.
        #expect(transport.requests.filter { $0 == "GET /api/v1/sankalpas" }.count == 2)
    }

    @Test("A refused session comes back as the app's own error, in the app's own words")
    func refusedSessionIsMappedBack() async {
        let transport = Fixture.readyTransport()
        transport.on("POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions", status: 422,
                     body: Fixture.problemJSON(
                        code: "SESSION_IN_FUTURE", detail: "Session cannot occur in the future"))
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let refusal = await service.logSession(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!),
            occurredAt: CalendarMoment(day: day(2026, 9, 20), hour: 7)
        )

        #expect(refusal == .session(.sessionInFuture))
        #expect(refusal?.message == "Only a session you have already performed can be logged.")
    }

    @Test(
        "Every lifecycle command reaches its own endpoint",
        arguments: [
            ("pause", "pause"), ("resume", "resume"), ("stop", "stop")
        ]
    )
    func lifecycleCommandsReachTheirEndpoints(name: String, path: String) async {
        let id = SankalpaId(UUID(uuidString: Fixture.sankalpaId)!)
        let transport = Fixture.readyTransport()
        transport.on("POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/\(path)",
                     body: Fixture.sankalpaJSON(state: "PAUSED"))
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let refusal: SankalpaCommandError?
        switch name {
        case "pause": refusal = await service.pause(id)
        case "resume": refusal = await service.resume(id)
        default: refusal = await service.stop(id)
        }

        #expect(refusal == nil)
        #expect(transport.requests.contains("POST /api/v1/sankalpas/\(Fixture.sankalpaId)/\(path)"))
    }

    /// Completing is the one lifecycle command that carries a body, and the outcome has to go out
    /// in the service's spelling.
    @Test("Completing sends the outcome the service understands")
    func completeSendsOutcome() async {
        let transport = Fixture.readyTransport()
        transport.on("POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/complete",
                     body: Fixture.sankalpaJSON(state: "COMPLETED_SUCCESSFULLY"))
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let refusal = await service.complete(
            SankalpaId(UUID(uuidString: Fixture.sankalpaId)!), outcome: .successfully
        )

        #expect(refusal == nil)
        #expect(transport.requests.contains("POST /api/v1/sankalpas/\(Fixture.sankalpaId)/complete"))
    }

    @Test("An illegal transition comes back naming both states")
    func refusedTransitionIsMappedBack() async {
        let transport = Fixture.readyTransport()
        transport.on("GET", "/api/v1/sankalpas", body: "[\(Fixture.sankalpaJSON(state: "STOPPED"))]")
        transport.on("POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/pause", status: 422,
                     body: Fixture.problemJSON(
                        code: "INVALID_LIFECYCLE_TRANSITION",
                        detail: "Cannot transition from STOPPED to PAUSED"))
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let refusal = await service.pause(SankalpaId(UUID(uuidString: Fixture.sankalpaId)!))

        #expect(refusal == .lifecycle(.invalidLifecycleTransition(from: .stopped, to: .paused)))
    }

    @Test("Declaring posts the declaration and then re-reads the practice")
    func declarePostsAndRefreshes() async {
        let transport = Fixture.readyTransport()
        transport.on("POST", "/api/v1/sankalpas", status: 201, body: Fixture.sankalpaJSON())
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let refusal = await service.declare(
            Declaration(
                title: "Vipassana", actionType: .meditation, startDate: day(2026, 9, 1),
                periodUnit: .day, timesPerPeriod: 2, periodCount: 30
            )
        )

        #expect(refusal == nil)
        #expect(transport.requests.contains("POST /api/v1/sankalpas"))
        #expect(transport.requests.filter { $0 == "GET /api/v1/sankalpas" }.count == 2)
    }

    /// A command that never arrived must not be reported as a rule the user broke.
    @Test("A command that cannot reach the service is reported as a connection failure")
    func unreachableCommandIsNotARuleRefusal() async {
        let transport = Fixture.readyTransport()
        let service = Fixture.service(transport: transport)
        await service.refresh()

        transport.failEverything(with: URLError(.notConnectedToInternet))
        let refusal = await service.pause(SankalpaId(UUID(uuidString: Fixture.sankalpaId)!))

        #expect(refusal?.message.contains("not connected") == true)
    }

    // MARK: - Session paging

    /// The service pages at 200. A practice longer than one page has to be read through, or the
    /// period arithmetic silently loses its oldest sessions.
    @Test("Session history is read past the first page")
    func readsEverySessionPage() async {
        let transport = Fixture.readyTransport()
        let first = (0..<200).map { "2026-09-01T\(String(format: "%02d", $0 % 24)):00:00" }
        transport.on("GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions?page=0&size=200",
                     body: Fixture.sessionPageJSON(occurrences: first, total: 201))
        transport.on("GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions?page=1&size=200",
                     body: Fixture.sessionPageJSON(
                        occurrences: ["2026-09-02T07:00:00"], total: 201))
        let service = Fixture.service(transport: transport)

        await service.refresh()

        #expect(transport.requests.contains(
            "GET /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions?page=1&size=200"
        ))
        #expect(service.queries.summaries().first?.totalSessions == 201)
    }
}
