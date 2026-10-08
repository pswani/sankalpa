import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

@MainActor
@Suite("Remote linked extensions")
struct LinkedExtensionTests {
    let root = Fixture.sankalpaId
    let child = "33333333-3333-3333-3333-333333333333"
    let instance = Fixture.serviceInstanceId

    nonisolated func row(_ id: String, count: Int, source: String? = nil, direct: String? = nil, facts: Int = 0) -> String {
        let end = count == 40 ? "2026-10-10" : count == 90 ? "2026-11-29" : "2027-02-27"
        return """
        {"id":"\(id)","title":"Sit","description":"","actionType":"MEDITATION",
         "startDate":"2026-09-01","endDate":"\(end)","periodUnit":"DAY","timesPerPeriod":1,
         "periodCount":\(count),"lifecycleState":"IN_PROGRESS","declaredAt":"\(source == nil ? "2026-09-01T06:00:00" : "2026-09-10T12:00:00")",
         "seriesId":"\(root)","extensionOf":\(source.map { "\"\($0)\"" } ?? "null"),
         "directExtensionId":\(direct.map { "\"\($0)\"" } ?? "null"),"totalSessionCount":\(facts)}
        """
    }
    nonisolated var history: String {
        """
        [{"from":"NOT_STARTED","to":"IN_PROGRESS","effectiveAt":"2026-09-01T06:00:00",
          "recordedAt":"2026-09-01T06:00:00","originSankalpaId":"\(root)","sequenceNumber":0}]
        """
    }
    func fact(contributors: [String], id: String = Fixture.sessionId) -> String {
        """
        {"id":"\(id)","sankalpaId":"\(root)","loggingSankalpaId":"\(root)",
         "occurredAt":"2026-09-05T08:00:00","loggedAt":"2026-09-05T09:00:00",
         "contributingSankalpaIds":[\(contributors.map { "\"\($0)\"" }.joined(separator: ","))]}
        """
    }
    func transport(extended: Bool = false, facts: Int = 0) -> StubTransport {
        let transport = StubTransport()
        transport.useResponseHeaders(["Sankalpa-Service-Instance": instance, "Sankalpa-Practice-Revision": "5"])
        transport.on("GET", "/api/v1/capabilities", body: "{\"sessionCommandIdentity\":1,\"linkedSankalpaExtensions\":1,\"serviceInstanceId\":\"\(instance)\"}")
        transport.on("GET", "/api/v1/sankalpas", body: "[" + row(root, count: 40, direct: extended ? child : nil, facts: facts)
            + (extended ? "," + row(child, count: 90, source: root, facts: facts) : "") + "]")
        transport.on("GET", "/api/v1/sankalpas/\(root)/lifecycle-history", body: history)
        transport.on("GET", "/api/v1/sankalpas/\(child)/lifecycle-history", body: history)
        let rows = facts == 0 ? "" : fact(contributors: extended ? [root, child] : [root])
        transport.on("GET", "/api/v1/sessions", body: "{\"content\":[\(rows)],\"nextCursor\":null,\"hasMore\":false}")
        return transport
    }
    nonisolated func bundle(_ id: String, count: Int = 90) -> String {
        let source = row(root, count: 40, direct: id)
        let extensionRow = row(id, count: count, source: root)
        return """
        {"created":true,"sankalpa":\(extensionRow),"series":[
          {"sankalpa":\(source),"lifecycleHistory":\(history)},
          {"sankalpa":\(extensionRow),"lifecycleHistory":\(history)}]}
        """
    }
    nonisolated func acceptExtension(on transport: StubTransport) {
        transport.on("POST", "/api/v1/sankalpas/\(root)/extensions") { request in
            let object = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return (201, bundle(object["id"] as! String))
        }
    }
    var rootId: SankalpaId { SankalpaId(UUID(uuidString: root)!) }
    var childId: SankalpaId { SankalpaId(UUID(uuidString: child)!) }

    @Test("Canonical refresh shares one fact across vows and pins every subsequent read")
    func canonicalRefresh() async throws {
        let transport = transport(extended: true, facts: 1)
        let service = Fixture.service(transport: transport)
        await service.refresh()
        #expect(service.isServiceReachable)
        #expect(service.queries.summaries().map(\.totalSessions) == [1, 1])
        #expect(service.queries.journal(from: day(2026, 9, 1), until: day(2026, 9, 10)).count == 1)
        #expect(service.allSessions(for: rootId).first?.id == service.allSessions(for: childId).first?.id)
        #expect(!transport.requests.contains(where: { $0.contains("/sankalpas/") && $0.contains("/sessions") }))
        for request in transport.sentRequests where request.url?.path.hasSuffix("lifecycle-history") == true || request.url?.path == "/api/v1/sessions" {
            #expect(request.value(forHTTPHeaderField: "Linked-Sankalpa-Version") == "1")
            #expect(request.value(forHTTPHeaderField: "Sankalpa-Practice-Revision") == "5")
        }
    }
    @Test("Creation caches the complete series and sends matching stable identity fields")
    func identifiedExtension() async throws {
        let transport = transport(); acceptExtension(on: transport)
        let service = Fixture.service(transport: transport); await service.refresh()
        guard case .accepted(let id, false) = await service.extend(rootId, totalPeriodCount: 90) else { Issue.record("expected accepted extension"); return }
        #expect(service.linkedSeries(id).count == 2)
        #expect(service.queries.summary(rootId)?.sankalpa.commitment.periodCount?.value == 40)
        #expect(service.queries.summary(id)?.sankalpa.commitment.periodCount?.value == 90)
        #expect(!service.hasExtensionAttempt)
        let request = try #require(transport.sentRequests.last { $0.httpMethod == "POST" })
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect((body["id"] as? String)?.lowercased() == request.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(request.value(forHTTPHeaderField: "Linked-Sankalpa-Version") == "1")
        #expect(body.count == 2)
    }
    @Test("A lost response and relaunch retry the same identity after the source changes")
    func durableReplay() async throws {
        let transport = transport(); let directory = Fixture.temporaryDirectory()
        let service = Fixture.service(transport: transport, cache: PracticeCache(directory: directory)); await service.refresh()
        transport.onAsync("POST", "/api/v1/sankalpas/\(root)/extensions") { _ in throw URLError(.timedOut) }
        guard case .pending = await service.extend(rootId, totalPeriodCount: 90) else { Issue.record("expected pending"); return }
        #expect(service.hasUnresolvedExtension)
        #expect(await service.relocate(to: ServiceLocation(host: "other", port: 8080)) == false)
        let first = try #require(transport.sentRequests.last { $0.httpMethod == "POST" })
        let replayTransport = self.transport(); acceptExtension(on: replayTransport)
        let relaunched = Fixture.service(transport: replayTransport, cache: PracticeCache(directory: directory))
        guard case .accepted = await relaunched.retryExtension() else { Issue.record("expected replay acceptance"); return }
        let second = try #require(replayTransport.sentRequests.last { $0.httpMethod == "POST" })
        #expect(first.httpBody == second.httpBody)
        #expect(first.value(forHTTPHeaderField: "Idempotency-Key") == second.value(forHTTPHeaderField: "Idempotency-Key"))
    }
    @Test("An unwritable attempt sends no extension command")
    func writeBeforeSend() async {
        let transport = transport()
        let cache = PracticeCache(directory: Fixture.temporaryDirectory(), writer: { data, url in
            if url.lastPathComponent == "sankalpa-extension.json" { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let service = Fixture.service(transport: transport, cache: cache); await service.refresh()
        guard case .refused = await service.extend(rootId, totalPeriodCount: 90) else { Issue.record("expected disk refusal"); return }
        #expect(!transport.requests.contains(where: { $0.hasPrefix("POST") }))
    }
    @Test("Accepted response survives cache failure and can be applied offline on relaunch")
    func acceptedAwaitingCache() async {
        final class FailureSwitch { var fail = false }
        let failure = FailureSwitch(); let transport = transport(); acceptExtension(on: transport)
        let directory = Fixture.temporaryDirectory()
        let cache = PracticeCache(directory: directory, writer: { data, url in
            if failure.fail && url.lastPathComponent == "sankalpa-cache.json" { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let service = Fixture.service(transport: transport, cache: cache); await service.refresh(); failure.fail = true
        guard case .pending = await service.extend(rootId, totalPeriodCount: 90) else { Issue.record("expected pending cache application"); return }
        #expect(service.hasUnresolvedExtension && service.linkedSeries(rootId).count == 1)
        let offline = self.transport(); offline.failEverything(with: URLError(.notConnectedToInternet))
        let relaunched = Fixture.service(transport: offline, cache: PracticeCache(directory: directory))
        guard case .accepted = await relaunched.retryExtension() else { Issue.record("expected cached acceptance"); return }
        #expect(relaunched.linkedSeries(rootId).count == 2 && !relaunched.hasExtensionAttempt)
        #expect(!offline.requests.contains(where: { $0.hasPrefix("POST") }))
    }
    @Test("Mismatched success is blocked and preserved rather than replaced with a new identity")
    func malformedSuccess() async {
        let transport = transport()
        transport.on("POST", "/api/v1/sankalpas/\(root)/extensions", status: 201, body: bundle(child))
        let service = Fixture.service(transport: transport); await service.refresh()
        guard case .blocked = await service.extend(rootId, totalPeriodCount: 90) else { Issue.record("expected protocol block"); return }
        let sent = transport.requests.filter { $0.hasPrefix("POST") }.count
        guard case .blocked = await service.retryExtension() else { Issue.record("expected preserved block"); return }
        #expect(transport.requests.filter { $0.hasPrefix("POST") }.count == sent)
        #expect(service.hasUnresolvedExtension && service.linkedSeries(rootId).count == 1)
    }
    @Test("Existing child conflict opens the authoritative duration and retains a notice until acknowledged")
    func existingChild() async {
        let transport = transport()
        transport.on("POST", "/api/v1/sankalpas/\(root)/extensions", status: 409, body: """
            {"code":"EXTENSION_ALREADY_EXISTS","detail":"Already extended","errors":{"extensionId":"\(child)"}}
            """)
        transport.on("GET", "/api/v1/sankalpas/\(child)/linked-series", body: """
            [{"sankalpa":\(row(root, count: 40, direct: child)),"lifecycleHistory":\(history)},
             {"sankalpa":\(row(child, count: 180, source: root)),"lifecycleHistory":\(history)}]
            """)
        let service = Fixture.service(transport: transport); await service.refresh()
        guard case .accepted(let id, true) = await service.extend(rootId, totalPeriodCount: 90) else { Issue.record("expected existing child"); return }
        #expect(id == childId)
        #expect(service.queries.summary(id)?.sankalpa.commitment.periodCount?.value == 180)
        #expect(service.extensionNotice?.contains("180") == true && service.hasExtensionAttempt)
        #expect(service.acknowledgeExtensionNotice() && !service.hasExtensionAttempt)
    }
    @Test("Pending creates and deletes project everywhere; switching members retains the recent guard")
    func pendingProjection() async throws {
        let transport = transport(extended: true)
        let service = Fixture.service(transport: transport); await service.refresh()
        transport.failEverything(with: URLError(.notConnectedToInternet))
        guard case .pending(let receipt) = await service.logSessionCommand(rootId, occurredAt: CalendarMoment(day: day(2026, 9, 10), hour: 8)) else { Issue.record("expected pending session"); return }
        #expect(service.queries.summaries().map(\.totalSessions) == [1, 1])
        #expect(service.shouldConfirmRepeat(for: childId))
        guard case .pending = await service.deleteSession(receipt.session) else { Issue.record("expected pending delete"); return }
        #expect(service.queries.summaries().map(\.totalSessions) == [0, 0])
        #expect(!service.shouldConfirmRepeat(for: childId))
        #expect(service.pendingDeletions.first?.sankalpaId == rootId)
    }
    @Test("Inconsistent aliases or duplicate canonical facts retain the previous valid cache")
    func invalidRefresh() async {
        let transport = transport(extended: true, facts: 1)
        let service = Fixture.service(transport: transport); await service.refresh()
        let duplicated = fact(contributors: [root, child])
        transport.on("GET", "/api/v1/sessions", body: "{\"content\":[\(duplicated),\(duplicated)],\"hasMore\":false,\"nextCursor\":null}")
        await service.refresh()
        #expect(service.isShowingCachedPractice && !service.isServiceReachable)
        #expect(service.queries.summaries().map(\.totalSessions) == [1, 1])
    }
    @Test("Capability rediscovery does not require practice snapshot headers")
    func capabilityHasIndependentContract() async throws {
        let transport = StubTransport()
        transport.on("GET", "/api/v1/capabilities", body: "{\"sessionCommandIdentity\":1,\"linkedSankalpaExtensions\":1,\"serviceInstanceId\":\"\(instance)\"}")
        let client = SankalpaAPIClient(baseURL: Fixture.location.url, transport: transport).linked(to: UUID(uuidString: instance)!)
        let value = try await client.capabilities()
        #expect(value.linkedSankalpaExtensions == 1)
        #expect(transport.sentRequests.last?.value(forHTTPHeaderField: "Linked-Sankalpa-Version") == nil)
    }

    @Test("A changed read snapshot restarts once and exhaustion preserves the cached practice")
    func snapshotRestartIsBounded() async {
        let transport = transport(extended: true, facts: 1)
        let service = Fixture.service(transport: transport)
        await service.refresh()
        let initialLists = transport.requests.filter { $0 == "GET /api/v1/sankalpas" }.count
        transport.on("GET", "/api/v1/sessions", status: 409, body: "{\"code\":\"READ_SNAPSHOT_CHANGED\",\"detail\":\"Changed\"}")
        await service.refresh()
        #expect(transport.requests.filter { $0 == "GET /api/v1/sankalpas" }.count == initialLists + 2)
        #expect(service.isShowingCachedPractice)
        #expect(service.queries.summaries().map(\.totalSessions) == [1, 1])
    }

    @Test("A linked response must include a revision, including a deletion receipt")
    func requiredRevision() async {
        let transport = transport()
        transport.useResponseHeaders(["Sankalpa-Service-Instance": instance])
        let client = SankalpaAPIClient(baseURL: Fixture.location.url, transport: transport).linked(to: UUID(uuidString: instance)!)
        do { _ = try await client.linkedList(); Issue.record("missing revision was accepted") }
        catch { #expect(error is WireDecodingError) }
        transport.on("DELETE", "/api/v1/sankalpas/\(root)/sessions/\(Fixture.sessionId)", status: 204, body: "")
        do {
            try await client.deleteSession(rootId, sessionId: SessionId(UUID(uuidString: Fixture.sessionId)!), serviceInstanceId: UUID(uuidString: instance)!)
            Issue.record("unbound deletion receipt was accepted")
        } catch { #expect(error is WireDecodingError) }
    }

    @Test("Journal migration preserves pending identities, binding and original backup bytes")
    func journalMigration() throws {
        let directory = Fixture.temporaryDirectory()
        let cache = PracticeCache(directory: directory)
        var journal = ReliabilityJournal(serviceLocation: Fixture.location.displayText)
        journal.schemaVersion = 2
        journal.capability = ServiceCapability(sessionCommandIdentity: 1, serviceInstanceId: UUID(uuidString: instance)!)
        let pending = PendingSession(sankalpaId: rootId, occurredAt: CalendarMoment(day: day(2026, 9, 5), hour: 8),
                                    loggedAt: CalendarMoment(day: day(2026, 9, 5), hour: 9), serviceInstanceId: journal.capability!.serviceInstanceId)
        journal.creates = [pending]
        journal.recentLogs = [RecentSessionLog(sessionId: pending.id, sankalpaId: rootId, acceptedAt: pending.loggedAt)]
        #expect(cache.saveJournal(journal))
        let original = try Data(contentsOf: directory.appendingPathComponent("sankalpa-outbox.json"))
        let loaded = cache.loadJournal(for: Fixture.location)
        #expect(loaded.schemaVersion == 3 && loaded.creates == [pending])
        #expect(loaded.recentLogs == journal.recentLogs && loaded.capability == journal.capability)
        #expect(try Data(contentsOf: directory.appendingPathComponent("sankalpa-outbox.pre-linked.json")) == original)
        #expect(cache.saveJournal(loaded))
        #expect(cache.loadJournal(for: Fixture.location).creates == [pending])
    }

    @Test("A late accepted extension cannot replace a newer canonical snapshot")
    func acceptedResultDoesNotRegressRevision() async throws {
        let transport = transport()
        let service = Fixture.service(transport: transport)
        await service.refresh()
        let gate = RequestGate()
        transport.onAsync("POST", "/api/v1/sankalpas/\(root)/extensions") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            await gate.suspendRequest()
            return (201, bundle(body["id"] as! String))
        }
        let submission = Task { await service.extend(rootId, totalPeriodCount: 90) }
        await gate.waitUntilReached()
        transport.useResponseHeaders(["Sankalpa-Service-Instance": instance, "Sankalpa-Practice-Revision": "6"])
        transport.on("GET", "/api/v1/sankalpas", body: "[" + row(root, count: 40, facts: 1) + "]")
        transport.on("GET", "/api/v1/sessions", body: "{\"content\":[\(fact(contributors: [root]))],\"nextCursor\":null,\"hasMore\":false}")
        await service.refresh()
        await gate.release()
        guard case .pending = await submission.value else { Issue.record("older acceptance should remain pending"); return }
        #expect(service.hasUnresolvedExtension)
        #expect(service.linkedSeries(rootId).count == 1)
        #expect(service.queries.summary(rootId)?.totalSessions == 1)
        transport.onAsync("POST", "/api/v1/sankalpas/\(root)/extensions") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return (201, bundle(body["id"] as! String))
        }
        guard case .accepted = await service.retryExtension() else { Issue.record("current replay should apply"); return }
        #expect(service.linkedSeries(rootId).count == 2)
        #expect(service.queries.summary(rootId)?.totalSessions == 1)
    }

    @Test("Canonical cursor refresh retains 201 distinct facts with identical performed times")
    func completeCursorHistory() async {
        let transport = transport(extended: true)
        transport.on("GET", "/api/v1/sankalpas", body: "[" + row(root, count: 40, direct: child, facts: 201)
            + "," + row(child, count: 90, source: root, facts: 201) + "]")
        let facts = (0..<201).map { _ in fact(contributors: [root, child], id: UUID().uuidString) }
        let first = "{\"content\":[" + facts.prefix(200).joined(separator: ",") + "],\"nextCursor\":\"opaque-token\",\"hasMore\":true}"
        let last = "{\"content\":[" + facts.last! + "],\"nextCursor\":null,\"hasMore\":false}"
        installCursorPages(on: transport, first: first, last: last)
        let service = Fixture.service(transport: transport)
        await service.refresh()
        #expect(service.isServiceReachable)
        #expect(service.queries.summaries().map(\.totalSessions) == [201, 201])
        #expect(service.queries.journal(from: day(2026, 9, 1), until: day(2026, 9, 10)).count == 201)
        #expect(transport.requests.filter { $0.hasPrefix("GET /api/v1/sessions") }.count == 2)
    }

    @Test("An unreadable session journal blocks new extension creation without losing its bytes")
    func unreadableJournalBlocksExtension() async throws {
        let directory = Fixture.temporaryDirectory()
        let url = directory.appendingPathComponent("sankalpa-outbox.json")
        let preserved = Data("unreadable pending operations".utf8)
        try preserved.write(to: url)
        let transport = transport()
        let service = Fixture.service(transport: transport, cache: PracticeCache(directory: directory))
        await service.refresh()
        guard case .refused = await service.extend(rootId, totalPeriodCount: 90) else { Issue.record("expected recovery refusal"); return }
        #expect(!transport.requests.contains { $0.hasPrefix("POST") })
        #expect(try Data(contentsOf: url) == preserved)
    }

    @Test("A mismatched linked completion receipt cannot acknowledge a win")
    func completionReceiptMustMatch() async {
        let transport = transport(extended: true)
        transport.on("POST", "/api/v1/sankalpas/\(root)/complete", body: row(root, count: 40, direct: child))
        let service = Fixture.service(transport: transport)
        await service.refresh()
        #expect(await service.complete(rootId, outcome: .successfully) != nil)
        #expect(service.queries.summary(rootId)?.state == .inProgress)
    }

    nonisolated func installCursorPages(on transport: StubTransport, first: String, last: String) {
        transport.on("GET", "/api/v1/sessions") { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            return (200, cursor == nil ? first : last)
        }
    }

}
