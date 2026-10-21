import XCTest
@testable import SankalpaConversation

@MainActor final class AssistantConversationStoreTests: XCTestCase {
    private struct Legacy: Encodable {
        let threadId: UUID
        let transcript: [AGUI.Message]
        let proposal: AssistantProposal?
        let confirmationId: UUID?
        let input: AGUI.RunAgentInput?
    }
    private func legacy(_ harness: ConversationHarness, record: AssistantConversationRecord) throws -> (URL, Data) {
        let value = Legacy(threadId: record.id, transcript: record.transcript, proposal: record.proposal,
            confirmationId: record.confirmationId, input: record.request?.input)
        let bytes = try JSONEncoder().encode(value)
        let url = harness.directory.appending(path: "\(harness.instance.uuidString)-linked-v1.json")
        try bytes.write(to: url)
        return (url, bytes)
    }
    func testLegacyUncertainConfirmationImportsOnceWithAllOriginalIdentities() async throws {
        let source = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .error])
        let original = await source.controller(client, negotiation: .init(linked: true, batchSessions: true))
        await original.ask("Declare"); await original.confirm()
        let record = try XCTUnwrap(original.session?.record)
        let target = try ConversationHarness(instance: source.instance)
        let (url, bytes) = try legacy(target, record: record)
        let store = target.store()
        let library = await store.open()
        XCTAssertNil(library.problem)
        let imported = try XCTUnwrap(library.selected)
        XCTAssertEqual(imported.id, record.id)
        XCTAssertEqual(imported.transcript, record.transcript)
        XCTAssertEqual(imported.proposal, record.proposal)
        XCTAssertEqual(imported.confirmationId, record.confirmationId)
        XCTAssertEqual(imported.request?.input, record.request?.input)
        XCTAssertTrue(imported.imported)
        var updated = imported; updated.draft = "After migration"
        _ = try await store.save(updated)
        let reopened = await target.store().open()
        XCTAssertEqual(reopened.selected?.draft, "After migration", "Legacy data must not replace new edits")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testMigrationCrashBeforeRecordAndBeforeReceiptIsRetryable() async throws {
        for boundary in 0...1 {
            let harness = try ConversationHarness()
            let record = AssistantConversationRecord(serviceInstanceId: harness.instance)
            let (url, bytes) = try legacy(harness, record: record)
            harness.faults.arm(allow: boundary)
            let interrupted = await harness.store().open()
            XCTAssertNotNil(interrupted.problem)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let recovered = await harness.store().open()
            XCTAssertNil(recovered.problem)
            XCTAssertEqual(recovered.selected?.id, record.id)
            XCTAssertEqual(recovered.summaries.count, 1)
        }
    }
    func testCorruptLegacyFailsClosedAndPreservesBytes() async throws {
        let harness = try ConversationHarness()
        let url = harness.directory.appending(path: "\(harness.instance.uuidString)-linked-v1.json")
        let bytes = Data("invalid".utf8); try bytes.write(to: url)
        let client = ScriptedClient(scripts: [])
        let controller = await harness.controller(client)
        await controller.ask("Must not send"); await controller.retry()
        XCTAssertNotNil(controller.storageProblem)
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(controller.conversations.isEmpty)
    }
    func testDivergentLegacyCollisionDoesNotOverwriteExistingRecord() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        let library = await store.open()
        var record = try XCTUnwrap(library.selected)
        _ = try legacy(harness, record: record)
        record.draft = "newer data"; _ = try await store.save(record)
        let reopened = await store.open()
        XCTAssertNotNil(reopened.problem)
        XCTAssertEqual(reopened.selected?.draft, "newer data")
    }
    func testUnreadableUnselectedRecordBlocksDeliveryButReadableChatSurvives() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        let library = await store.open()
        let id = try XCTUnwrap(library.selected?.id)
        let damaged = await store.root.appending(path: "\(UUID().uuidString).json")
        let bytes = Data("{broken".utf8); try bytes.write(to: damaged)
        let client = ScriptedClient(scripts: [])
        let controller = await harness.controller(client)
        XCTAssertEqual(controller.session?.threadId, id)
        XCTAssertEqual(controller.damagedFiles.count, 1)
        await controller.ask("Blocked")
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: damaged), bytes)
    }
    func testBadSelectionPointerFallsBackWithoutChangingRecords() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        let library = await store.open()
        let record = try XCTUnwrap(library.selected)
        let root = await store.root
        try Data("invalid pointer".utf8).write(to: root.appending(path: "selection.json"))
        let reopened = await store.open()
        XCTAssertNil(reopened.problem)
        XCTAssertEqual(reopened.selected?.id, record.id)
        let persisted = try await store.load(record.id)
        XCTAssertEqual(record, persisted)
    }
    func testUnknownRecordSchemaAndCrossThreadRequestArePreservedAndBlocked() async throws {
        for invalidSchema in [false, true] {
            let harness = try ConversationHarness()
            let store = harness.store()
            let library = await store.open()
            var record = try XCTUnwrap(library.selected)
            if invalidSchema { record.schemaVersion = 99 }
            else {
                record.request = .init(kind: .ordinary,
                    input: .init(threadId: UUID(), runId: UUID(), messages: [.init(role: "user", content: "x")], tools: AGUI.Tool.supportedFrontendTools), negotiation: .init())
            }
            let url = await store.root.appending(path: "\(record.id.uuidString).json")
            let bytes = try JSONEncoder().encode(record); try bytes.write(to: url)
            let reopened = await store.open()
            XCTAssertNotNil(reopened.problem)
            XCTAssertNil(reopened.selected)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testStaleRecordCannotEraseDraftPatchOrRequestState() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        let library = await store.open()
        let old = try XCTUnwrap(library.selected)
        var checkpoint = old
        let input = AGUI.RunAgentInput(threadId: old.id, runId: UUID(), messages: [.init(role: "user", content: "question")], tools: AGUI.Tool.supportedFrontendTools)
        checkpoint.request = .init(kind: .ordinary, input: input, negotiation: .init())
        _ = try await store.save(checkpoint)
        let patched = try await store.saveDraft("new draft", id: old.id, now: Date())
        XCTAssertEqual(patched.request?.input, input)
        do { _ = try await store.save(old); XCTFail("Stale replacement must fail") }
        catch { XCTAssertTrue(error is AssistantStorageError) }
        let persisted = try await store.load(old.id)
        XCTAssertEqual(persisted.draft, "new draft")
        XCTAssertEqual(persisted.request?.input, input)
    }
    func testFailedSelectionKeepsOldPointerAndLeavesRecoverableOrphan() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        let library = await store.open()
        let a = try XCTUnwrap(library.selected)
        harness.faults.arm(allow: 1)
        do { _ = try await store.create(); XCTFail("Selection write must fail") } catch { }
        let reopened = await store.open()
        XCTAssertEqual(reopened.selected?.id, a.id)
        XCTAssertEqual(reopened.summaries.count, 2)
    }
    func testFutureSelectionSchemaIsPreservedAndCannotEnableDelivery() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        _ = await store.open()
        let pointer = await store.root.appending(path: "selection.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pointer)) as? [String: Any])
        object["schemaVersion"] = 99
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: pointer)
        let reopened = await store.open()
        XCTAssertNotNil(reopened.problem)
        XCTAssertNotNil(reopened.selected, "Readable history should remain inspectable")
        XCTAssertEqual(try Data(contentsOf: pointer), bytes)
        if let record = reopened.selected {
            do { try await store.select(record.id); XCTFail("Navigation must not downgrade a future manifest") }
            catch { XCTAssertTrue(error is AssistantStorageError) }
        }
        XCTAssertEqual(try Data(contentsOf: pointer), bytes)
    }
    func testChangedLegacyAfterImportIsNotMergedOrSilentlyIgnored() async throws {
        let harness = try ConversationHarness()
        let record = AssistantConversationRecord(serviceInstanceId: harness.instance)
        let (url, _) = try legacy(harness, record: record)
        let store = harness.store()
        _ = await store.open()
        let changed = Data("old application overwrote its checkpoint".utf8)
        try changed.write(to: url)
        let reopened = await store.open()
        XCTAssertNotNil(reopened.problem)
        XCTAssertEqual(reopened.selected?.id, record.id)
        XCTAssertEqual(try Data(contentsOf: url), changed)
    }
    func testConcurrentDraftPatchesCannotOverwriteAtomicResponseMerge() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        let library = await store.open()
        var record = try XCTUnwrap(library.selected)
        let input = AGUI.RunAgentInput(threadId: record.id, runId: UUID(), messages: [.init(role: "user", content: "request")], tools: AGUI.Tool.supportedFrontendTools)
        record.request = .init(kind: .ordinary, input: input, negotiation: .init())
        _ = try await store.save(record)
        let id = record.id
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for index in 0..<30 {
                tasks.addTask { _ = try await store.saveDraft("draft \(index)", id: id, now: Date()) }
            }
            tasks.addTask {
                _ = try await store.update(id) { value in
                    value.request = nil
                    value.transcript.append(.init(role: "assistant", content: "response"))
                }
            }
            try await tasks.waitForAll()
        }
        let saved = try await store.load(id)
        XCTAssertNil(saved.request)
        XCTAssertEqual(saved.transcript.last?.content, "response")
        XCTAssertTrue(saved.draft.hasPrefix("draft "))
        XCTAssertEqual(saved.revision, 32)
    }
    func testOfflineLegacyImportResolvesMissingHeadersOnFirstVerifiedRetry() async throws {
        let source = try ConversationHarness()
        let client = ScriptedClient(scripts: [.error, .success(text: "Recovered")])
        let supported = AssistantNegotiation(linked: true, batchSessions: true, beginCorrection: true)
        let original = await source.controller(client, negotiation: supported)
        await original.ask("Request could have produced a history-repair proposal")
        let target = try ConversationHarness(instance: source.instance)
        _ = try legacy(target, record: XCTUnwrap(original.session?.record))
        target.faults.arm(allow: 1) // Record saved offline; receipt lost before reconnect/restart.
        let offline = await target.controller(client, availability: { "Offline" })
        XCTAssertTrue(offline.session?.record.request?.negotiationInferred == true)
        XCTAssertNotNil(offline.storageProblem)
        XCTAssertEqual(client.inputs.count, 1)
        var usedNegotiation: AssistantNegotiation?
        let online = AssistantConversationController(store: target.store(), negotiation: supported,
            makeClient: { negotiation in usedNegotiation = negotiation; return client })
        await online.open()
        XCTAssertNil(online.storageProblem, "Changing connectivity must not change a staged import payload")
        await online.retry()
        XCTAssertEqual(usedNegotiation, supported)
        XCTAssertEqual(client.inputs[0], client.inputs[1])
        XCTAssertNil(online.session?.record.request)
    }
}
