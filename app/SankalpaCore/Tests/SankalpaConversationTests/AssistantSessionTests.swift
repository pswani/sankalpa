import XCTest
@testable import SankalpaConversation

@MainActor
final class AssistantSessionTests: XCTestCase {
    func testBatchConfirmationSurvivesRelaunchWithTheSameIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "recovery.json")
        let client = ScriptedClient(scripts: [.batch(UUID()), .error, .success(text: "30 sessions logged.")])
        let first = AssistantSession(client: client, recoveryURL: url)
        first.composer = "Record these days"; await first.send(); await first.confirm()
        let second = AssistantSession(client: client, recoveryURL: url)
        XCTAssertEqual(second.threadId, first.threadId)
        guard case .awaitingConfirmation(let proposal) = second.state else { return XCTFail("Missing recovered card") }
        XCTAssertEqual(proposal.kind, .logSessions)
        XCTAssertEqual(proposal.newSessionCount, 1)
        await second.confirm()
        let resumes = client.inputs.compactMap(\.resume?.first)
        XCTAssertEqual(resumes.count, 2)
        XCTAssertEqual(resumes[0].payload, resumes[1].payload)
        XCTAssertEqual(second.transcript.last?.content, "30 sessions logged.")
    }
    func testInterruptedProposalRequestRecoversWithTheOriginalRunIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "recovery.json")
        let client = ScriptedClient(scripts: [.error, .batch(UUID())])
        let first = AssistantSession(client: client, recoveryURL: url)
        first.composer = "Record daily"; await first.send()
        let second = AssistantSession(client: client, recoveryURL: url)
        await second.recover()
        XCTAssertEqual(client.inputs[0].runId, client.inputs[1].runId)
        XCTAssertEqual(client.inputs[0].messages, client.inputs[1].messages)
        guard case .awaitingConfirmation = second.state else { return XCTFail("Did not recover") }
    }
    func testUnresolvedLocalChangesBlockSending() async {
        let client = ScriptedClient(scripts: [])
        let session = AssistantSession(client: client, prepareSend: { false })
        session.composer = "Record daily"; await session.send()
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertFalse(session.composer.isEmpty)
    }
    func testUnknownProposalVersionCanBeCancelledButNeverConfirmed() async {
        let client = ScriptedClient(scripts: [.unsupported(UUID()), .success(text: "Cancelled")])
        let session = AssistantSession(client: client)
        session.composer = "Record daily"; await session.send(); await session.confirm()
        XCTAssertEqual(client.inputs.count, 1)
        guard case .awaitingConfirmation(let proposal) = session.state else { return XCTFail("Missing unsupported card") }
        XCTAssertFalse(proposal.canConfirm)
        await session.cancel(); XCTAssertEqual(client.inputs.count, 2)
    }
    func testCorruptRecoveryFileSendsNothingAndPreservesBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "recovery.json"), bytes = Data("invalid".utf8)
        try bytes.write(to: url)
        let client = ScriptedClient(scripts: [])
        let session = AssistantSession(client: client, recoveryURL: url)
        session.composer = "Record"; await session.send(); await session.recover()
        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testCorrectionCancelsBeforeStartingNewOrdinaryRun() async throws {
        let proposal = UUID()
        let client = ScriptedClient(scripts: [
            .proposal(proposal), .success(text: "Cancelled."), .success(text: "Corrected.")
        ])
        let session = AssistantSession(client: client)
        session.composer = "Log a session"; await session.send()
        session.composer = "Actually, use 8 PM"; await session.send()

        let inputs = client.inputs
        XCTAssertEqual(inputs.count, 3)
        guard inputs.count == 3 else { return }
        XCTAssertEqual(inputs[1].resume?.first?.status, "cancelled")
        XCTAssertNil(inputs[2].resume)
        XCTAssertEqual(inputs[2].messages.last?.content, "Actually, use 8 PM")
    }

    func testConfirmationRetryPreservesConfirmationIdentity() async throws {
        let proposal = UUID()
        let client = ScriptedClient(scripts: [
            .proposal(proposal), .error, .success(text: "Saved.")
        ])
        let session = AssistantSession(client: client)
        session.composer = "Declare"; await session.send(); await session.confirm(); await session.confirm()
        let resumes = client.inputs.compactMap(\.resume?.first)
        XCTAssertEqual(resumes.count, 2)
        XCTAssertEqual(resumes[0].payload, resumes[1].payload)
    }

    func testExpiredConfirmationRemovesTheProposalCard() async {
        let client = ScriptedClient(scripts: [.proposal(UUID()), .expired])
        let session = AssistantSession(client: client)
        session.composer = "Declare"; await session.send()
        await session.confirm()

        XCTAssertEqual(session.state, .failed("Expired"))
    }

    func testEditingSpeechTranscriptDoesNotSendUntilExplicitSend() async {
        let client = ScriptedClient(scripts: [.success(text: "Done")])
        let session = AssistantSession(client: client)
        session.composer = "Transcript ready for review"

        XCTAssertTrue(client.inputs.isEmpty)
        XCTAssertEqual(session.state, .readyToSend)
        await session.send()
        XCTAssertEqual(client.inputs.count, 1)
    }

    func testCommittedMutationWithFailedRefreshIsShownAsSavedButStale() async {
        let client = ScriptedClient(scripts: [.successWithRefresh(text: "Saved.")])
        let session = AssistantSession(client: client, handleTool: { _ in false })
        session.composer = "Confirm it"

        await session.send()

        XCTAssertTrue(session.staleAfterSave)
        XCTAssertEqual(session.transcript.last?.content, "Saved.")
    }
}

private final class ScriptedClient: AssistantRunClient, @unchecked Sendable {
    enum Script { case proposal(UUID), batch(UUID), unsupported(UUID), success(text: String), successWithRefresh(text: String), error, expired }
    private let lock = NSLock(); private var scripts: [Script]; private var stored: [AGUI.RunAgentInput] = []
    init(scripts: [Script]) { self.scripts = scripts }
    var inputs: [AGUI.RunAgentInput] { lock.withLock { stored } }

    func run(_ input: AGUI.RunAgentInput) -> AsyncThrowingStream<AGUI.Event, Error> {
        let script = lock.withLock { stored.append(input); return scripts.removeFirst() }
        return AsyncThrowingStream { continuation in
            continuation.yield(.runStarted(threadId: input.threadId, runId: input.runId))
            switch script {
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
                    "id": .string(proposal.uuidString), "expiresAt": .string("2026-10-17T18:00:00-05:00"),
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
                    "id": .string(proposal.uuidString), "expiresAt": .string("2026-09-24T18:00:00-05:00"),
                    "metadata": .object(["proposalType": .string("DECLARE_SANKALPA"), "proposalVersion": .number(1), "title": .string("Meditate")])
                ])])])
                continuation.yield(.runFinished(threadId: input.threadId, runId: input.runId, outcome: outcome))
            }
            continuation.finish()
        }
    }
}
