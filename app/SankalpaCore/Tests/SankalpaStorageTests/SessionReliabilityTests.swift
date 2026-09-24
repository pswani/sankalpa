import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

@MainActor
@Suite("Session reliability")
struct SessionReliabilityTests {
    private final class WriteFailureSwitch {
        var failCache = false
        var armOnResponse = false
    }
    private let sankalpaId = SankalpaId(UUID(uuidString: Fixture.sankalpaId)!)
    private let moment = CalendarMoment(day: day(2026, 9, 10), hour: 7)

    @Test("A create sends one identity in the body and both required headers")
    func identifiedCreateContract() async throws {
        let transport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: transport)
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)
        guard case .accepted(let receipt) = result else {
            Issue.record("expected accepted create")
            return
        }
        let request = try #require(transport.sentRequests.last {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/sessions") == true
        })
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(object["id"] == receipt.session.id.value.uuidString)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == object["id"])
        #expect(request.value(forHTTPHeaderField: "Sankalpa-Service-Instance")?.lowercased()
                == Fixture.serviceInstanceId)
    }

    @Test("A refresh started before an accepted create cannot erase it")
    func staleRefreshCannotEraseAcceptedCreate() async {
        let transport = Fixture.readyTransport()
        transport.on(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: Fixture.sessionPageJSON(occurrences: [])
        )
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let gate = RequestGate()
        transport.onAsync(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ) { _ in
            await gate.suspendRequest()
            return (200, Fixture.sessionPageJSON(occurrences: []))
        }
        Fixture.acceptsLoggedSession(on: transport)
        let staleRefresh = Task { await service.refresh() }
        await gate.waitUntilReached()

        guard case .accepted(let receipt) = await service.logSessionCommand(
            sankalpaId, occurredAt: moment
        ) else {
            Issue.record("expected accepted create")
            await gate.release()
            await staleRefresh.value
            return
        }
        await gate.release()
        await staleRefresh.value

        #expect(service.allSessions(for: sankalpaId).map(\.id) == [receipt.session.id])
        #expect(service.queries.summaries().first?.totalSessions == 1)
    }

    @Test("A refresh started before an accepted deletion cannot resurrect it")
    func staleRefreshCannotResurrectAcceptedDeletion() async throws {
        let transport = Fixture.readyTransport()
        transport.on(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: Fixture.sessionPageJSON(ids: [Fixture.sessionId])
        )
        transport.on(
            "DELETE", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions/\(Fixture.sessionId)",
            status: 204, body: ""
        )
        let service = Fixture.service(transport: transport)
        await service.refresh()
        let session = try #require(service.allSessions(for: sankalpaId).first)

        let gate = RequestGate()
        transport.onAsync(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ) { _ in
            await gate.suspendRequest()
            return (200, Fixture.sessionPageJSON(ids: [Fixture.sessionId]))
        }
        let staleRefresh = Task { await service.refresh() }
        await gate.waitUntilReached()

        guard case .accepted = await service.deleteSession(session) else {
            Issue.record("expected accepted deletion")
            await gate.release()
            await staleRefresh.value
            return
        }
        await gate.release()
        await staleRefresh.value

        #expect(service.allSessions(for: sankalpaId).isEmpty)
        #expect(service.queries.summaries().first?.totalSessions == 0)
    }

    @Test("A retry after a lost response reuses the exact session identity")
    func retryReusesIdentity() async throws {
        let directory = Fixture.temporaryDirectory()
        let cache = PracticeCache(directory: directory)
        let firstTransport = Fixture.readyTransport()
        let first = Fixture.service(transport: firstTransport, cache: cache)
        await first.sync()

        firstTransport.failEverything(with: URLError(.networkConnectionLost))
        let result = await first.logSessionCommand(sankalpaId, occurredAt: moment)
        guard case .pending(let receipt) = result else {
            Issue.record("expected durable pending create")
            return
        }

        let retryTransport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: retryTransport, status: 200)
        retryTransport.on(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: Fixture.sessionPageJSON(
                occurrences: ["2026-09-10T07:00:00"],
                ids: [receipt.session.id.value.uuidString]
            )
        )
        let relaunched = Fixture.service(transport: retryTransport, cache: cache)
        await relaunched.sync()

        let request = try #require(retryTransport.sentRequests.first {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/sessions") == true
        })
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(object["id"] == receipt.session.id.value.uuidString)
        #expect(relaunched.pending.isEmpty)
        #expect(relaunched.queries.summaries().first?.totalSessions == 1)
    }

    @Test("Two intentional sessions at the same performed time remain distinct")
    func sameTimeDistinctIdentities() async throws {
        let transport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: transport)
        let service = Fixture.service(transport: transport)
        await service.refresh()

        _ = await service.logSessionCommand(sankalpaId, occurredAt: moment)
        _ = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        let ids = try transport.sentRequests
            .filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/sessions") == true }
            .map { request -> String in
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                return try #require(object["id"])
            }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(service.queries.summaries().first?.currentPeriod?.performed == 2)
    }

    @Test("Undo of a pending create becomes a durable delete and stays excluded")
    func pendingUndoBecomesDelete() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = Fixture.service(transport: transport, cache: cache)
        await service.sync()
        let originalTotal = service.queries.summaries().first?.totalSessions

        transport.failEverything(with: URLError(.notConnectedToInternet))
        let log = await service.logSessionCommand(sankalpaId, occurredAt: moment)
        guard case .pending(let receipt) = log else {
            Issue.record("expected pending create")
            return
        }
        let deletion = await service.deleteSession(receipt.session)

        guard case .pending = deletion else {
            Issue.record("expected pending deletion")
            return
        }
        #expect(service.pending.isEmpty)
        #expect(service.pendingDeletions.map(\.id) == [receipt.session.id])
        #expect(service.queries.summaries().first?.totalSessions == originalTotal)

        let relaunched = Fixture.service(transport: transport, cache: cache)
        #expect(relaunched.pending.isEmpty)
        #expect(relaunched.pendingDeletions.map(\.id) == [receipt.session.id])
        #expect(relaunched.queries.summaries().first?.totalSessions == originalTotal)
    }

    @Test("A rejected deletion restores the session and leaves a durable notice")
    func rejectedDeleteRestoresSession() async throws {
        let transport = Fixture.readyTransport()
        transport.on(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: Fixture.sessionPageJSON(
                ids: [Fixture.sessionId]
            )
        )
        transport.on(
            "DELETE", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions/\(Fixture.sessionId)",
            status: 409,
            body: Fixture.problemJSON(
                code: "SESSION_IDENTITY_CONFLICT", detail: "Identity belongs elsewhere", status: 409
            )
        )
        let service = Fixture.service(transport: transport)
        await service.refresh()
        let session = try #require(service.queries.sessions(
            sankalpaId, from: day(2026, 9, 1), until: day(2026, 9, 30)
        ).first)

        let result = await service.deleteSession(session)

        guard case .rejected = result else {
            Issue.record("expected stable deletion rejection")
            return
        }
        #expect(service.pendingDeletions.isEmpty)
        #expect(service.queries.summaries().first?.totalSessions == 1)
        #expect(service.reconciliationNotices.first?.contains("could not be deleted") == true)
        service.acknowledgeReconciliationNotices()
        #expect(service.reconciliationNotices.isEmpty)
    }

    @Test("Pending deletions immediately recalculate open and closed periods")
    func pendingDeletionRecalculatesEveryDerivedRead() async throws {
        let transport = Fixture.readyTransport()
        let ids = (0..<4).map { _ in UUID().uuidString }
        transport.on(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: Fixture.sessionPageJSON(
                occurrences: [
                    "2026-09-09T07:00:00", "2026-09-09T08:00:00",
                    "2026-09-10T07:00:00", "2026-09-10T08:00:00"
                ],
                ids: ids
            )
        )
        let service = Fixture.service(transport: transport)
        await service.refresh()
        let closedDay = day(2026, 9, 9)
        let openDay = day(2026, 9, 10)
        #expect(service.queries.summaries().first?.totalSessions == 4)
        #expect(service.queries.summaries().first?.currentPeriod?.performed == 2)
        #expect(service.queries.periodOutcomes(
            sankalpaId, from: closedDay, until: closedDay
        ).first?.standing == .satisfied)

        let closedSession = try #require(
            service.allSessions(for: sankalpaId).first { $0.occurredAt.day == closedDay }
        )
        let openSession = try #require(
            service.allSessions(for: sankalpaId).first { $0.occurredAt.day == openDay }
        )
        transport.failEverything(with: URLError(.notConnectedToInternet))
        guard case .pending = await service.deleteSession(closedSession),
              case .pending = await service.deleteSession(openSession)
        else {
            Issue.record("expected both deletions to remain durably pending")
            return
        }

        #expect(service.pendingDeletions.count == 2)
        #expect(service.allSessions(for: sankalpaId).count == 2)
        #expect(service.queries.summaries().first?.totalSessions == 2)
        #expect(service.queries.summaries().first?.currentPeriod?.performed == 1)
        let closedAfter = try #require(service.queries.periodOutcomes(
            sankalpaId, from: closedDay, until: closedDay
        ).first)
        #expect(closedAfter.standing == .unsatisfied)
        #expect(closedAfter.missed == 1)
    }

    @Test("Pending operations prevent implicit relocation to another service")
    func pendingOperationBlocksRelocation() async {
        let transport = Fixture.readyTransport()
        let service = Fixture.service(transport: transport)
        await service.sync()
        transport.failEverything(with: URLError(.notConnectedToInternet))
        _ = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        let changed = await service.relocate(to: ServiceLocation(host: "other.local"))

        #expect(!changed)
        #expect(service.serviceLocation == Fixture.location)
        #expect(service.pending.count == 1)
    }

    @Test("An unreadable journal blocks session mutation instead of being overwritten")
    func corruptJournalBlocksMutation() async throws {
        let directory = Fixture.temporaryDirectory()
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("sankalpa-outbox.json"), options: .atomic
        )
        let cache = PracticeCache(directory: directory)
        let transport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: transport)
        let service = Fixture.service(transport: transport, cache: cache)
        await service.refresh()

        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        guard case .rejected(let error) = result else {
            Issue.record("expected blocked mutation")
            return
        }
        #expect(error.message.contains("preserved"))
        #expect(!transport.requests.contains("POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"))
    }

    @Test("A service-instance mismatch preserves the pending command")
    func serviceMismatchPreservesCommand() async {
        let transport = Fixture.readyTransport()
        transport.on(
            "POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            status: 409,
            body: Fixture.problemJSON(
                code: "SERVICE_INSTANCE_MISMATCH", detail: "Service instance changed", status: 409
            )
        )
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        guard case .pending(let receipt) = result else {
            Issue.record("expected the command to remain pending")
            return
        }
        #expect(service.pending.map(\.id) == [receipt.session.id])
        #expect(service.reconciliationNotices.first?.contains("service at this address has changed") == true)
    }

    @Test("Capability discovery cannot rebind pending work to a replacement service")
    func replacementServiceCannotRebindPendingWork() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let original = Fixture.readyTransport()
        let first = Fixture.service(transport: original, cache: cache)
        await first.sync()
        original.failEverything(with: URLError(.networkConnectionLost))
        _ = await first.logSessionCommand(sankalpaId, occurredAt: moment)

        let replacement = Fixture.readyTransport()
        replacement.on("GET", "/api/v1/capabilities", body: """
            {"sessionCommandIdentity":1,
             "serviceInstanceId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}
            """)
        Fixture.acceptsLoggedSession(on: replacement)
        let stranded = Fixture.service(transport: replacement, cache: cache)
        await stranded.sync()

        #expect(stranded.pending.count == 1)
        #expect(!replacement.requests.contains(
            "POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ))
        #expect(stranded.refreshFailure?.contains("different Sankalpa service") == true)

        // The failed negotiation must not corrupt or rewrite the durable binding. Returning to the
        // original service can still replay the exact operation after another process launch.
        let recoveredTransport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: recoveredTransport, status: 200)
        let recovered = Fixture.service(transport: recoveredTransport, cache: cache)
        await recovered.sync()
        #expect(recovered.pending.isEmpty)
        #expect(recoveredTransport.requests.contains(
            "POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ))
    }

    @Test("A reachable capability downgrade revokes later offline mutation authority")
    func capabilityDowngradeRevokesOfflineAuthority() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let transport = Fixture.readyTransport()
        let service = Fixture.service(transport: transport, cache: cache)
        await service.sync()

        transport.on("GET", "/api/v1/capabilities", body: """
            {"sessionCommandIdentity":0,
             "serviceInstanceId":"\(Fixture.serviceInstanceId)"}
            """)
        await service.refresh()
        transport.failEverything(with: URLError(.notConnectedToInternet))
        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        guard case .rejected = result else {
            Issue.record("expected the downgraded service to block offline logging")
            return
        }
        #expect(service.pending.isEmpty)
        #expect(!transport.requests.contains(
            "POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ))
    }

    @Test("A transient server problem never turns a pending create into a rejection")
    func transientServerProblemStaysPending() async {
        let transport = Fixture.readyTransport()
        transport.on(
            "POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            status: 500,
            body: Fixture.problemJSON(
                code: "INTERNAL_ERROR", detail: "Try again later", status: 500
            )
        )
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        guard case .pending(let receipt) = result else {
            Issue.record("expected an indeterminate response to remain pending")
            return
        }
        #expect(service.pending.map(\.id) == [receipt.session.id])
        #expect(service.reconciliationNotices.isEmpty)
    }

    @Test("A rejection stays pending when its journal correction cannot be saved")
    func rejectedCreateWaitsForDurableCorrection() async {
        let directory = Fixture.temporaryDirectory()
        let failure = WriteFailureSwitch()
        let cache = PracticeCache(directory: directory) { data, url in
            if failure.failCache && url.lastPathComponent == "sankalpa-outbox.json" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
        let transport = Fixture.readyTransport()
        transport.on(
            "POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ) { _ in
            failure.failCache = true
            return (409, Fixture.problemJSON(
                code: "SESSION_IDENTITY_CONFLICT", detail: "Identity conflict", status: 409
            ))
        }
        let service = Fixture.service(transport: transport, cache: cache)
        await service.refresh()

        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        guard case .pending(let receipt) = result else {
            Issue.record("expected the unpersisted correction to remain pending")
            return
        }
        #expect(service.pending.map(\.id) == [receipt.session.id])
        #expect(service.reconciliationNotices.isEmpty)
    }

    @Test("A deletion rejection stays pending when restoring it cannot be saved")
    func rejectedDeletionWaitsForDurableCorrection() async throws {
        let directory = Fixture.temporaryDirectory()
        let failure = WriteFailureSwitch()
        let cache = PracticeCache(directory: directory) { data, url in
            if failure.failCache && url.lastPathComponent == "sankalpa-outbox.json" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
        let transport = Fixture.readyTransport()
        transport.on(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: Fixture.sessionPageJSON(ids: [Fixture.sessionId])
        )
        transport.on(
            "DELETE", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions/\(Fixture.sessionId)"
        ) { _ in
            failure.failCache = true
            return (409, Fixture.problemJSON(
                code: "SESSION_IDENTITY_CONFLICT", detail: "Identity conflict", status: 409
            ))
        }
        let service = Fixture.service(transport: transport, cache: cache)
        await service.refresh()
        let session = try #require(service.allSessions(for: sankalpaId).first)

        let result = await service.deleteSession(session)

        guard case .pending = result else {
            Issue.record("expected the unpersisted restoration to remain pending")
            return
        }
        #expect(service.pendingDeletions.map(\.id) == [session.id])
        #expect(service.allSessions(for: sankalpaId).isEmpty)
        #expect(service.reconciliationNotices.isEmpty)
    }

    @Test("A mismatched success is quarantined and never retried automatically")
    func mismatchedSuccessIsQuarantined() async {
        let transport = Fixture.readyTransport()
        transport.on(
            "POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: """
                {"id":"\(UUID().uuidString)","sankalpaId":"\(Fixture.sankalpaId)",
                 "occurredAt":"2026-09-10T07:00:00","loggedAt":"2026-09-10T12:00:00"}
                """
        )
        let service = Fixture.service(transport: transport)
        await service.refresh()

        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)
        guard case .pending(let receipt) = result else {
            Issue.record("expected protocol-violating success to remain pending")
            return
        }
        #expect(service.quarantinedCreateIds == [receipt.session.id])
        #expect(service.reconciliationNotices.count == 1)
        let postsBeforeSync = transport.requests.count {
            $0 == "POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        }

        await service.sync()

        let postsAfterSync = transport.requests.count {
            $0 == "POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        }
        #expect(postsAfterSync == postsBeforeSync)
    }

    @Test("A protocol mismatch is not reported as quarantined until quarantine is durable")
    func mismatchedSuccessWaitsForDurableQuarantine() async {
        let directory = Fixture.temporaryDirectory()
        let failure = WriteFailureSwitch()
        let cache = PracticeCache(directory: directory) { data, url in
            if failure.failCache && url.lastPathComponent == "sankalpa-outbox.json" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
        let transport = Fixture.readyTransport()
        transport.on(
            "POST", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ) { _ in
            if failure.armOnResponse {
                failure.failCache = true
                failure.armOnResponse = false
            }
            return (200, """
                {"id":"\(UUID().uuidString)","sankalpaId":"\(Fixture.sankalpaId)",
                 "occurredAt":"2026-09-10T07:00:00","loggedAt":"2026-09-10T12:00:00"}
                """)
        }
        let service = Fixture.service(transport: transport, cache: cache)
        await service.refresh()
        failure.armOnResponse = true

        guard case .pending(let receipt) = await service.logSessionCommand(
            sankalpaId, occurredAt: moment
        ) else {
            Issue.record("expected protocol mismatch to remain pending")
            return
        }
        #expect(service.quarantinedCreateIds.isEmpty)
        #expect(service.reconciliationNotices.isEmpty)

        failure.failCache = false
        await service.sync()

        #expect(service.quarantinedCreateIds == [receipt.session.id])
        #expect(service.reconciliationNotices.count == 1)
    }

    @Test("A pending deletion suppresses the repeat guard and a rejection restores it")
    func deletionSuppressesAndRestoresRecentGuard() async {
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let online = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: online)
        let service = Fixture.service(transport: online, cache: cache)
        await service.refresh()
        let log = await service.logSessionCommand(sankalpaId, occurredAt: moment)
        guard case .accepted(let receipt) = log else {
            Issue.record("expected accepted create")
            return
        }
        #expect(service.shouldConfirmRepeat(for: sankalpaId))

        online.failEverything(with: URLError(.notConnectedToInternet))
        guard case .pending = await service.deleteSession(receipt.session) else {
            Issue.record("expected pending deletion")
            return
        }
        #expect(!service.shouldConfirmRepeat(for: sankalpaId))

        let rejecting = Fixture.readyTransport()
        rejecting.on(
            "GET", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions",
            body: Fixture.sessionPageJSON(
                occurrences: ["2026-09-10T07:00:00"],
                ids: [receipt.session.id.value.uuidString]
            )
        )
        rejecting.on(
            "DELETE", "/api/v1/sankalpas/\(Fixture.sankalpaId)/sessions/\(receipt.session.id.value.uuidString)",
            status: 409,
            body: Fixture.problemJSON(
                code: "SESSION_IDENTITY_CONFLICT", detail: "Identity conflict", status: 409
            )
        )
        let relaunched = Fixture.service(transport: rejecting, cache: cache)
        await relaunched.sync()

        #expect(relaunched.pendingDeletions.isEmpty)
        #expect(relaunched.shouldConfirmRepeat(for: sankalpaId))
        #expect(relaunched.reconciliationNotices.count == 1)
    }

    @Test("A warned discard is the only way an unreadable journal can resume mutation")
    func explicitDiscardRecoversCorruptJournal() async throws {
        let directory = Fixture.temporaryDirectory()
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("sankalpa-outbox.json"), options: .atomic
        )
        let cache = PracticeCache(directory: directory)
        let transport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: transport)
        let service = Fixture.service(transport: transport, cache: cache)
        await service.refresh()

        #expect(service.reliabilityProblem != nil)
        #expect(service.discardUnrecoverableSessionChanges())
        guard case .accepted = await service.logSessionCommand(sankalpaId, occurredAt: moment) else {
            Issue.record("mutation did not resume after explicit discard")
            return
        }
        #expect(service.reliabilityProblem == nil)
    }

    @Test("An old-format outbox is preserved and never value-matched or sent")
    func legacyOutboxFailsClosedWithoutChangingItsBytes() async throws {
        let directory = Fixture.temporaryDirectory()
        let legacy = [PendingSession(
            sankalpaId: sankalpaId, occurredAt: moment, loggedAt: moment
        )]
        let original = try JSONEncoder().encode(legacy)
        let url = directory.appendingPathComponent("sankalpa-outbox.json")
        try original.write(to: url, options: .atomic)
        let transport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: transport)
        let service = Fixture.service(
            transport: transport, cache: PracticeCache(directory: directory)
        )

        await service.sync()
        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        #expect(service.reliabilityProblem?.contains("Older pending sessions") == true)
        #expect(try Data(contentsOf: url) == original)
        guard case .rejected = result else {
            Issue.record("expected legacy recovery to block a new session mutation")
            return
        }
        #expect(!transport.requests.contains(
            "POST /api/v1/sankalpas/\(Fixture.sankalpaId)/sessions"
        ))
    }

    @Test("Duplicate operation identities make the journal fail closed")
    func duplicateJournalIdentityIsNeverLoadedOrOverwritten() async throws {
        let directory = Fixture.temporaryDirectory()
        let instance = try #require(UUID(uuidString: Fixture.serviceInstanceId))
        let entry = PendingSession(
            sankalpaId: sankalpaId, occurredAt: moment, loggedAt: moment,
            serviceInstanceId: instance
        )
        var invalid = ReliabilityJournal(serviceLocation: Fixture.location.displayText)
        invalid.capability = ServiceCapability(
            sessionCommandIdentity: 1, serviceInstanceId: instance
        )
        invalid.creates = [entry, entry]
        let original = try JSONEncoder().encode(invalid)
        let url = directory.appendingPathComponent("sankalpa-outbox.json")
        try original.write(to: url, options: .atomic)
        let service = Fixture.service(
            transport: Fixture.readyTransport(), cache: PracticeCache(directory: directory)
        )

        await service.sync()

        #expect(service.reliabilityProblem != nil)
        #expect(service.pending.isEmpty)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("A server-accepted create stays pending until local finalization is durable")
    func acceptedCreateWaitsForDurableFinalization() async {
        let directory = Fixture.temporaryDirectory()
        let failure = WriteFailureSwitch()
        let cache = PracticeCache(directory: directory) { data, url in
            if failure.failCache && url.lastPathComponent == "sankalpa-cache.json" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
        let transport = Fixture.readyTransport()
        Fixture.acceptsLoggedSession(on: transport)
        let service = Fixture.service(transport: transport, cache: cache)
        await service.refresh()
        failure.failCache = true

        let result = await service.logSessionCommand(sankalpaId, occurredAt: moment)

        guard case .pending(let receipt) = result else {
            Issue.record("expected local finalization to remain pending")
            return
        }
        #expect(service.pending.map(\.id) == [receipt.session.id])
        #expect(service.queries.summaries().first?.currentPeriod?.performed == 1)
    }
}
