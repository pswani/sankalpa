import XCTest
@testable import SankalpaConversation

@MainActor final class AssistantConversationTests: XCTestCase {
    func testNewIsolatedConversationAndDraftSelectionSurviveRestart() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.success(text: "Hello")])
        let controller = await harness.controller(client)
        let a = try XCTUnwrap(controller.session?.threadId)
        await controller.ask("  First    conversation\nwith detail  ")
        controller.updateDraft("unfinished A")
        await controller.newConversation()
        let b = try XCTUnwrap(controller.session?.threadId)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(controller.session?.transcript.isEmpty == true)
        XCTAssertEqual(controller.session?.composer, "")
        await controller.newConversation()
        XCTAssertEqual(controller.session?.threadId, b)
        XCTAssertEqual(controller.conversations.count, 2)
        await controller.select(a)
        XCTAssertEqual(controller.session?.composer, "unfinished A")
        XCTAssertEqual(controller.session?.title, "First conversation with detail")
        let relaunched = await harness.controller(client)
        XCTAssertEqual(relaunched.session?.threadId, a)
        XCTAssertEqual(client.inputs.count, 1)
    }
    func testProposalStaysWithItsThreadAndSelectionDoesNotReorderHistory() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .success(text: "B reply")])
        let controller = await harness.controller(client)
        await controller.ask("A proposal")
        let a = try XCTUnwrap(controller.session?.threadId)
        let proposal = controller.session?.proposal
        await controller.newConversation()
        let b = try XCTUnwrap(controller.session?.threadId)
        await controller.ask("B question")
        XCTAssertEqual(client.inputs[1].messages.map(\.content), ["B question"])
        XCTAssertNil(client.inputs[1].parentRunId)
        let order = controller.conversations.map(\.id)
        await controller.select(a)
        XCTAssertEqual(controller.session?.proposal, proposal)
        XCTAssertEqual(controller.conversations.map(\.id), order)
        await controller.select(b)
        XCTAssertNil(controller.session?.proposal)
    }
    func testUncertaintyInUnselectedChatIsVisibleAndBlocksOtherSends() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.error, .success(text: "Recovered")])
        let controller = await harness.controller(client)
        await controller.ask("A uncertain")
        let a = try XCTUnwrap(controller.session?.threadId)
        await controller.newConversation()
        XCTAssertNotEqual(controller.session?.threadId, a)
        await controller.ask("B should wait")
        XCTAssertEqual(client.inputs.count, 1)
        XCTAssertEqual(controller.recoveryConversationId, a)
        await controller.select(a); await controller.retry()
        XCTAssertTrue(controller.canSend)
    }
    func testActiveRunReservesOwnerAndBlocksDoubleSendNewAndSelection() async throws {
        let harness = try ConversationHarness()
        let client = HeldConversationClient()
        let controller = await harness.controller(client)
        let original = try XCTUnwrap(controller.session?.threadId)
        controller.updateDraft("Hold")
        let task = Task { await controller.send() }
        await client.waitUntilStarted()
        XCTAssertTrue(client.didStart)
        XCTAssertTrue(controller.isBusy)
        await controller.newConversation(); await controller.select(original); await controller.send()
        XCTAssertEqual(controller.conversations.count, 1)
        client.finish(); await task.value
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.session?.transcript.map(\.content), ["Hold", "Finished"])
    }
    func testDraftEditDuringRunMergesWithTerminalResult() async throws {
        let harness = try ConversationHarness()
        let client = HeldConversationClient()
        let controller = await harness.controller(client)
        controller.updateDraft("Question")
        let task = Task { await controller.send() }
        await client.waitUntilStarted()
        controller.updateDraft("Next draft")
        let flushed = await controller.flushDraft()
        XCTAssertTrue(flushed)
        client.finish(); await task.value
        let reopened = await harness.controller(ScriptedClient(scripts: []))
        XCTAssertEqual(reopened.session?.composer, "Next draft")
        XCTAssertEqual(reopened.session?.transcript.last?.content, "Finished")
    }
    func testOfflineAllowsDraftsAndHistoryWithoutAnyDelivery() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [])
        let controller = await harness.controller(client, availability: { "Offline" })
        let a = try XCTUnwrap(controller.session?.threadId)
        controller.updateDraft("A offline draft")
        await controller.newConversation()
        await controller.ask("B offline draft")
        await controller.select(a)
        XCTAssertEqual(controller.session?.composer, "A offline draft")
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(controller.networkProblem, "Offline")
    }
    func testDifferentServiceHasIndependentLibraryAndRecoveryGate() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.error])
        let a = await harness.controller(client)
        await a.ask("Uncertain on A")
        let b = await harness.controller(client, instance: UUID())
        XCTAssertTrue(b.canSend)
        XCTAssertEqual(b.conversations.count, 1)
        XCTAssertTrue(b.session?.transcript.isEmpty == true)
        let back = await harness.controller(client)
        XCTAssertEqual(back.recoveryConversationId, a.session?.threadId)
    }
    func testFullDisplayHistoryAndBoundedModelContext() async throws {
        let harness = try ConversationHarness()
        let store = harness.store()
        let library = await store.open()
        var record = try XCTUnwrap(library.selected)
        record.transcript = (0..<100).map { AGUI.Message(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "message \($0)") }
        _ = try await store.save(record)
        let client = ScriptedClient(scripts: [.success(text: "done")])
        let controller = await harness.controller(client)
        await controller.ask("latest")
        XCTAssertEqual(client.inputs[0].messages.count, 20)
        XCTAssertEqual(client.inputs[0].messages.last?.content, "latest")
        let reopened = await harness.controller(client)
        XCTAssertEqual(reopened.session?.transcript.count, 102)
    }
    func testMessageUTF16AndWholeBodyBudgetsKeepOversizedDraftEditable() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.success(text: "small reply")])
        let controller = await harness.controller(client, maxBytes: 1800)
        await controller.ask(String(repeating: "😀", count: 8001))
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(controller.session?.transcript.count, 0)
        XCTAssertFalse(controller.session?.composer.isEmpty == true)
        await controller.ask(String(repeating: "a", count: 2000))
        XCTAssertTrue(client.inputs.isEmpty)
        await controller.ask("small")
        XCTAssertEqual(client.inputs.count, 1)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(client.inputs[0]).count, 1800)
    }
    func testRequestCheckpointFailureSendsNothingAndCanBeRetriedAfterReload() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.success(text: "done")])
        let controller = await harness.controller(client)
        controller.updateDraft("Keep me")
        _ = await controller.flushDraft()
        harness.faults.arm()
        await controller.send()
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(controller.session?.composer, "Keep me")
        XCTAssertNotNil(controller.storageProblem)
        await controller.reloadStorage(); await controller.send()
        XCTAssertEqual(client.inputs.count, 1)
    }
    func testTerminalWriteFailurePreservesDurableUnresolvedRequest() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.success(text: "lost answer"), .success(text: "retried answer")])
        client.onRun = { [faults = harness.faults] in faults.arm() }
        let controller = await harness.controller(client)
        await controller.ask("Persist before delivery")
        XCTAssertNotNil(controller.storageProblem)
        XCTAssertTrue(controller.session?.needsRecovery == true)
        client.onRun = nil
        let reopened = await harness.controller(client)
        XCTAssertTrue(reopened.session?.needsRecovery == true)
        await reopened.retry()
        XCTAssertEqual(client.inputs[0], client.inputs[1])
        XCTAssertEqual(reopened.session?.transcript.map(\.content), ["Persist before delivery", "retried answer"])
    }
    func testInterruptedCancellationRestoresCorrectionForExplicitSend() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .error, .success(text: "Cancelled"), .success(text: "Correction")])
        let first = await harness.controller(client)
        await first.ask("Original"); await first.ask("Correction draft")
        let second = await harness.controller(client)
        await second.retry()
        XCTAssertEqual(client.inputs.count, 3)
        XCTAssertEqual(second.session?.composer, "Correction draft")
        XCTAssertNil(second.session?.proposal)
        await second.send()
        XCTAssertEqual(client.inputs[3].messages.last?.content, "Correction draft")
    }
    func testExpiredLocalProposalCannotConfirmAndAskAgainSettlesThroughCancel() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .success(text: "Cancelled")])
        let controller = await harness.controller(client)
        await controller.ask("Original")
        let store = harness.store()
        var record = try await store.load(try XCTUnwrap(controller.session?.threadId))
        let proposal = try XCTUnwrap(record.proposal)
        record.proposal = try AssistantProposal(outcome: .object(["type": .string("interrupt"), "interrupts": .array([.object([
            "id": .string(proposal.id.uuidString), "expiresAt": .string("2000-01-01T00:00:00Z"), "metadata": .object(proposal.metadata)])])]))
        _ = try await store.save(record)
        let reopened = await harness.controller(client)
        await reopened.confirm()
        XCTAssertEqual(client.inputs.count, 1)
        await reopened.cancel()
        XCTAssertEqual(client.inputs[1].resume?.first?.status, "cancelled")
    }
    func testUnsupportedSavedNegotiationDoesNotDowngradeRetry() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.error])
        let old = await harness.controller(client, negotiation: .init(linked: true, batchSessions: true))
        await old.ask("Uncertain")
        let downgraded = await harness.controller(client)
        await downgraded.retry()
        XCTAssertEqual(client.inputs.count, 1)
        XCTAssertTrue(downgraded.session?.needsRecovery == true)
        XCTAssertTrue(downgraded.session?.errorMessage?.contains("compatible") == true)
    }
    func testSuspendPreservesOldRequestAndRejectsLatePublication() async throws {
        let harness = try ConversationHarness()
        let client = HeldConversationClient()
        let old = await harness.controller(client)
        old.updateDraft("Old binding request")
        let task = Task { await old.send() }
        await client.waitUntilStarted()
        let suspended = await old.suspend()
        XCTAssertTrue(suspended)
        client.finish(); await task.value
        XCTAssertNil(old.pendingNavigation)
        XCTAssertFalse(old.canSend)
        let rebound = await harness.controller(ScriptedClient(scripts: []))
        XCTAssertTrue(rebound.session?.needsRecovery == true)
        XCTAssertEqual(rebound.session?.transcript.count, 1)
    }
    func testInterpretingFailureKeepsHistoryTitleAndEditableDraft() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.server("ASSISTANT_COULD_NOT_INTERPRET")])
        let controller = await harness.controller(client)
        await controller.ask("My first request")
        XCTAssertEqual(controller.session?.title, "My first request")
        XCTAssertEqual(controller.session?.composer, "My first request")
        XCTAssertNil(controller.recoveryConversationId)
        XCTAssertTrue(controller.canSend)
    }
    func testAlreadyResolvedDecisionReconcilesWithoutClaimingNothingWasSaved() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .server("PROPOSAL_ALREADY_RESOLVED")])
        let controller = await harness.controller(client)
        await controller.ask("Declare"); await controller.confirm()
        XCTAssertNil(controller.session?.proposal)
        XCTAssertNil(controller.recoveryConversationId)
        XCTAssertTrue(controller.session?.errorMessage?.contains("Check the refreshed practice") == true)
        XCTAssertEqual(client.inputs.count, 2)
    }
    func testConfirmationPolicyReservesConversationBeforeAwaitingUserChoice() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID())])
        let controller = await harness.controller(client)
        await controller.ask("Create proposal")
        let original = controller.session?.threadId
        await controller.confirm { _, _ in
            XCTAssertTrue(controller.isBusy)
            await controller.newConversation()
            XCTAssertEqual(controller.session?.threadId, original)
        }
        XCTAssertEqual(client.inputs.count, 1)
        XCTAssertFalse(controller.isBusy)
    }
    func testTitleAndPreviewBoundsRespectGraphemeClusters() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.success(text: String(repeating: "long reply ", count: 20))])
        let controller = await harness.controller(client)
        await controller.ask(String(repeating: "👨‍👩‍👧‍👦", count: 61))
        let summary = try XCTUnwrap(controller.conversations.first)
        XCTAssertEqual(summary.title.count, 60)
        XCTAssertTrue(summary.title.hasSuffix("…"))
        XCTAssertEqual(summary.preview.count, 100)
        XCTAssertTrue(summary.preview.hasSuffix("…"))
    }
    func testRetryCannotStartWhileConversationSelectionIsBeingSaved() async throws {
        let harness = try ConversationHarness()
        let barrier = SelectionWriteBarrier()
        let store = AssistantConversationStore(serviceInstanceId: harness.instance, assistantDirectory: harness.directory,
            beforeWrite: { barrier.write($0) })
        let client = ScriptedClient(scripts: [.error])
        let controller = AssistantConversationController(store: store, makeClient: { _ in client })
        await controller.open()
        await controller.ask("Uncertain request")
        let id = try XCTUnwrap(controller.session?.threadId)
        barrier.arm()
        let selection = Task { await controller.select(id) }
        await barrier.waitUntilPaused()
        XCTAssertTrue(controller.isLoading)
        XCTAssertFalse(controller.canRetry)
        await controller.retry()
        XCTAssertEqual(client.inputs.count, 1)
        barrier.release()
        await selection.value
        XCTAssertTrue(controller.canRetry)
    }
}
