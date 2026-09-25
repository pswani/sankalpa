import XCTest
@testable import SankalpaConversation

@MainActor
final class AssistantSessionTests: XCTestCase {
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
        let session = AssistantSession(client: client) { _ in false }
        session.composer = "Confirm it"

        await session.send()

        XCTAssertTrue(session.staleAfterSave)
        XCTAssertEqual(session.transcript.last?.content, "Saved.")
    }
}

private final class ScriptedClient: AssistantRunClient, @unchecked Sendable {
    enum Script { case proposal(UUID), success(text: String), successWithRefresh(text: String), error }
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
            case .proposal(let proposal):
                let outcome: JSONValue = .object(["type": .string("interrupt"), "interrupts": .array([.object([
                    "id": .string(proposal.uuidString), "expiresAt": .string("2026-09-24T18:00:00-05:00"),
                    "metadata": .object(["proposalType": .string("DECLARE_SANKALPA"), "title": .string("Meditate")])
                ])])])
                continuation.yield(.runFinished(threadId: input.threadId, runId: input.runId, outcome: outcome))
            }
            continuation.finish()
        }
    }
}
