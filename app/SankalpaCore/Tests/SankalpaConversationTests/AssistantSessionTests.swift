import XCTest
@testable import SankalpaConversation

@MainActor
final class AssistantSessionTests: XCTestCase {
    func testBatchConfirmationSurvivesRelaunchWithExactRequestIdentity() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.batch(UUID()), .error, .success(text: "30 sessions logged.")])
        let first = await harness.controller(client)
        await first.ask("Record these days")
        let proposal = try XCTUnwrap(first.session?.proposal)
        XCTAssertEqual(proposal.kind, .logSessions)
        XCTAssertEqual(proposal.newSessionCount, 1)
        await first.confirm()
        let second = await harness.controller(client)
        XCTAssertEqual(second.session?.threadId, first.session?.threadId)
        XCTAssertEqual(client.inputs.count, 2, "Opening must not retry a confirmation")
        XCTAssertTrue(second.session?.needsRecovery == true)
        await second.retry()
        XCTAssertEqual(client.inputs[1], client.inputs[2], "Retry must preserve the whole original input")
        XCTAssertEqual(second.session?.transcript.last?.content, "30 sessions logged.")
    }
    func testInterruptedProposalRequestRecoversOriginalInputOnlyOnExplicitRetry() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.error, .batch(UUID())])
        let first = await harness.controller(client)
        await first.ask("Record daily")
        let second = await harness.controller(client)
        XCTAssertEqual(client.inputs.count, 1)
        await second.retry()
        XCTAssertEqual(client.inputs[0], client.inputs[1])
        XCTAssertEqual(second.session?.proposal?.kind, .logSessions)
    }
    func testUnresolvedLocalChangesBlockSendingAndKeepDraft() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [])
        let controller = await harness.controller(client, prepare: { false })
        await controller.ask("Record daily")
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(controller.session?.composer, "Record daily")
    }
    func testUnknownProposalCanBeCancelledButNeverConfirmed() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.unsupported(UUID()), .success(text: "Cancelled")])
        let controller = await harness.controller(client)
        await controller.ask("Record daily"); await controller.confirm()
        XCTAssertEqual(client.inputs.count, 1)
        XCTAssertFalse(try XCTUnwrap(controller.session?.proposal).canConfirm)
        await controller.cancel()
        XCTAssertEqual(client.inputs.count, 2)
        XCTAssertNil(controller.session?.proposal)
    }
    func testCorrectionCancelsBeforeNewOrdinaryRun() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .success(text: "Cancelled."), .success(text: "Corrected.")])
        let controller = await harness.controller(client)
        await controller.ask("Log a session"); await controller.ask("Actually, use 8 PM")
        XCTAssertEqual(client.inputs.count, 3)
        XCTAssertEqual(client.inputs[1].resume?.first?.status, "cancelled")
        XCTAssertNil(client.inputs[2].resume)
        XCTAssertEqual(client.inputs[2].messages.last?.content, "Actually, use 8 PM")
    }
    func testUncertainDecisionCannotBeChangedAndRetryKeepsConfirmation() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .error, .success(text: "Saved.")])
        let controller = await harness.controller(client)
        await controller.ask("Declare"); await controller.confirm()
        await controller.confirm(); await controller.cancel()
        XCTAssertEqual(client.inputs.count, 2, "Only explicit recovery may retry an uncertain decision")
        await controller.retry()
        XCTAssertEqual(client.inputs[1], client.inputs[2])
    }
    func testExpiredServerOutcomeSettlesProposalAndUncertainty() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .expired])
        let controller = await harness.controller(client)
        await controller.ask("Declare"); await controller.confirm()
        XCTAssertNil(controller.session?.proposal)
        XCTAssertNil(controller.recoveryConversationId)
        XCTAssertEqual(controller.session?.errorMessage, "Expired")
    }
    func testEditingDraftDoesNotSendUntilExplicitSend() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.success(text: "Done")])
        let controller = await harness.controller(client)
        controller.updateDraft("Transcript ready for review")
        XCTAssertTrue(client.inputs.isEmpty)
        await controller.send()
        XCTAssertEqual(client.inputs.count, 1)
    }
    func testSavedMutationFailedRefreshSurvivesRelaunchAndRetriesOnlyRefresh() async throws {
        let harness = try ConversationHarness()
        let client = ScriptedClient(scripts: [.proposal(UUID()), .success(text: "Saved.")])
        let first = await harness.controller(client, refresh: { false })
        await first.ask("Declare"); await first.confirm()
        XCTAssertTrue(first.session?.staleAfterSave == true)
        let second = await harness.controller(client)
        XCTAssertTrue(second.session?.staleAfterSave == true)
        await second.retry()
        XCTAssertEqual(client.inputs.count, 2, "Reconciliation must not replay the saved mutation")
        XCTAssertFalse(second.session?.staleAfterSave == true)
    }
}

final class ScriptedClient: AssistantRunClient, @unchecked Sendable {
    enum Script { case proposal(UUID), batch(UUID), unsupported(UUID), success(text: String), successWithRefresh(text: String), error, expired, server(String) }
    private let lock = NSLock(); private var scripts: [Script]; private var stored: [AGUI.RunAgentInput] = []
    init(scripts: [Script]) { self.scripts = scripts }
    var inputs: [AGUI.RunAgentInput] { lock.withLock { stored } }

    var onRun: (@Sendable () -> Void)?

    func run(_ input: AGUI.RunAgentInput) -> AsyncThrowingStream<AGUI.Event, Error> {
        let script = lock.withLock { stored.append(input); return scripts.isEmpty ? Script.server("UNEXPECTED_TEST_REQUEST") : scripts.removeFirst() }
        onRun?()
        return AsyncThrowingStream { continuation in
            continuation.yield(.runStarted(threadId: input.threadId, runId: input.runId))
            switch script {
            case .server(let code):
                continuation.yield(.runError(threadId: input.threadId, runId: input.runId, code: code, message: code))
            case .error:
                continuation.yield(.runError(threadId: input.threadId, runId: input.runId,
                    code: "ASSISTANT_UNAVAILABLE", message: "Try again"))
            case .expired:
                continuation.yield(.runError(threadId: input.threadId, runId: input.runId,
                    code: "PROPOSAL_EXPIRED", message: "Expired"))
            case .success(let text), .successWithRefresh(let text):
                let id = UUID(); continuation.yield(.textStart(threadId: input.threadId, runId: input.runId, messageId: id))
                continuation.yield(.textContent(threadId: input.threadId, runId: input.runId, messageId: id, delta: text))
                continuation.yield(.textEnd(threadId: input.threadId, runId: input.runId, messageId: id))
                if case .successWithRefresh = script {
                    let tool = UUID()
                    continuation.yield(.toolStart(threadId: input.threadId, runId: input.runId,
                                                  toolCallId: tool, name: "refresh_practice"))
                    continuation.yield(.toolArgs(threadId: input.threadId, runId: input.runId,
                                                 toolCallId: tool, delta: "{\"reason\":\"SESSION_LOGGED\"}"))
                    continuation.yield(.toolEnd(threadId: input.threadId, runId: input.runId,
                                                toolCallId: tool))
                }
                continuation.yield(.runFinished(threadId: input.threadId, runId: input.runId, outcome: .object(["type": .string("success")])))
            case .batch(let proposal), .unsupported(let proposal):
                let version: Double = { if case .unsupported = script { return 999 }; return 2 }()
                let outcome: JSONValue = .object(["type": .string("interrupt"), "interrupts": .array([.object([
                    "id": .string(proposal.uuidString), "expiresAt": .string("2099-10-17T18:00:00-05:00"),
                    "metadata": .object(["proposalType": .string("LOG_SESSIONS"), "proposalVersion": .number(version),
                        "sankalpaId": .string(UUID().uuidString), "sankalpaTitle": .string("Observe"),
                        "batch": .object(["requestedCount": .number(1), "timezone": .string("America/Chicago"),
                            "plan": .object(["mode": .string("EXPLICIT_TIMESTAMPS")]),
                            "entries": .array([.object(["sessionId": .string(UUID().uuidString), "occurredAt": .string("2026-10-16T20:00:00")])]),
                            "skippedDays": .array([]), "repeatWarnings": .array([])])])
                ])])])
                continuation.yield(.runFinished(threadId: input.threadId, runId: input.runId, outcome: outcome))
            case .proposal(let proposal):
                let outcome: JSONValue = .object(["type": .string("interrupt"), "interrupts": .array([.object([
                    "id": .string(proposal.uuidString), "expiresAt": .string("2099-09-24T18:00:00-05:00"),
                    "metadata": .object(["proposalType": .string("DECLARE_SANKALPA"), "proposalVersion": .number(1), "title": .string("Meditate")])
                ])])])
                continuation.yield(.runFinished(threadId: input.threadId, runId: input.runId, outcome: outcome))
            }
            continuation.finish()
        }
    }
}
