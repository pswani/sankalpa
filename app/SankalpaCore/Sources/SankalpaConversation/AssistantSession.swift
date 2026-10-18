import Foundation
import Observation
import os

/// Diagnostics for assistant runs (Console.app, subsystem `com.sankalpa`). Never the transcript.
private let assistantLog = Logger(subsystem: "com.sankalpa", category: "assistant")

public protocol AssistantRunClient: Sendable {
    func run(_ input: AGUI.RunAgentInput) -> AsyncThrowingStream<AGUI.Event, Error>
}
extension AGUIClient: AssistantRunClient {}

@MainActor
@Observable
public final class AssistantSession {
    public enum State: Equatable {
        case idle, readyToSend, running(UUID), awaitingConfirmation(AssistantProposal)
        case resolvingProposal(UUID), failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var transcript: [AGUI.Message] = []
    public var composer = "" {
        didSet {
            guard !isBusy else { return }
            if case .awaitingConfirmation = state { return }
            state = composer.isEmpty ? .idle : .readyToSend
        }
    }
    public private(set) var staleAfterSave = false
    public private(set) var errorMessage: String?
    public let threadId: UUID
    private let client: any AssistantRunClient
    private let handleTool: @MainActor @Sendable (FrontendToolCall) async -> Bool
    private var lastRunId: UUID?
    private var pendingConfirmationId: UUID?
    private var queuedCorrection: String?
    private var pendingProposal: AssistantProposal?
    private let recoveryURL: URL?
    private let prepareSend: @MainActor @Sendable () async -> Bool
    private var recoveryInput: AGUI.RunAgentInput?
    private var recoveryProblem = false
    private struct Checkpoint: Codable {
        let threadId: UUID
        let transcript: [AGUI.Message]
        let proposal: AssistantProposal?
        let confirmationId: UUID?
        let input: AGUI.RunAgentInput?
    }

    public init(threadId: UUID = UUID(), client: any AssistantRunClient,
                recoveryURL: URL? = nil,
                prepareSend: @escaping @MainActor @Sendable () async -> Bool = { true },
                handleTool: @escaping @MainActor @Sendable (FrontendToolCall) async -> Bool = { _ in true }) {
        self.recoveryURL = recoveryURL; self.prepareSend = prepareSend
        self.client = client; self.handleTool = handleTool
        if let recoveryURL, FileManager.default.fileExists(atPath: recoveryURL.path) {
            do {
                let saved = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: recoveryURL))
                self.threadId = saved.threadId; self.transcript = saved.transcript
                self.pendingProposal = saved.proposal; self.pendingConfirmationId = saved.confirmationId
                self.recoveryInput = saved.input
                if let proposal = saved.proposal { state = .awaitingConfirmation(proposal) }
            } catch {
                self.threadId = threadId; self.recoveryProblem = true
                self.errorMessage = "Assistant recovery data could not be read. Keep it for recovery before starting another request."
                self.state = .failed(self.errorMessage!)
            }
        } else { self.threadId = threadId }
    }

    public var isBusy: Bool {
        switch state { case .running, .resolvingProposal: true; default: false }
    }

    public func send() async {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, !recoveryProblem else { return }
        guard await prepareSend() else {
            errorMessage = "Synchronize pending practice changes before using the assistant."; return
        }
        if case .awaitingConfirmation = state {
            queuedCorrection = text
            _ = await cancel()
            return
        }
        composer = ""
        transcript.append(.init(role: "user", content: text))
        await perform(messages: transcript, resume: nil, reuseRunId: nil)
    }

    public func confirm() async {
        guard case .awaitingConfirmation(let proposal) = state, proposal.canConfirm, !recoveryProblem else { return }
        let confirmation = pendingConfirmationId ?? UUID()
        pendingConfirmationId = confirmation
        let payload: JSONValue = .object([
            "decision": .string("confirm"),
            "confirmationId": .string(confirmation.uuidString)
        ])
        await perform(messages: [], resume: [.init(interruptId: proposal.id, status: "resolved", payload: payload)], reuseRunId: nil)
    }

    @discardableResult
    public func cancel() async -> Bool {
        guard case .awaitingConfirmation(let proposal) = state else { return false }
        let success = await perform(messages: [], resume: [.init(interruptId: proposal.id, status: "cancelled")], reuseRunId: nil)
        if success, let correction = queuedCorrection {
            queuedCorrection = nil; composer = correction; await send()
        }
        return success
    }

    public func retryConfirmation() async { await confirm() }

    public func recover() async {
        guard !recoveryProblem, !isBusy, pendingProposal == nil, let input = recoveryInput else { return }
        _ = await perform(messages: input.messages, resume: input.resume, reuseRunId: input.runId)
    }

    private func saveCheckpoint() throws {
        guard let recoveryURL else { return }
        let checkpoint = Checkpoint(threadId: threadId, transcript: Array(transcript.suffix(80)), proposal: pendingProposal,
                                    confirmationId: pendingConfirmationId, input: recoveryInput)
        let data = try JSONEncoder().encode(checkpoint)
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: recoveryURL, options: .atomic)
    }

    @discardableResult
    private func perform(messages: [AGUI.Message], resume: [AGUI.Resume]?, reuseRunId: UUID?) async -> Bool {
        let runId = reuseRunId ?? UUID(); let parentRunId = lastRunId; lastRunId = runId
        state = resume == nil ? .running(runId) : .resolvingProposal(runId)
        errorMessage = nil
        let input = AGUI.RunAgentInput(threadId: threadId, runId: runId,
            parentRunId: parentRunId, messages: messages,
            tools: AGUI.Tool.supportedFrontendTools, resume: resume)
        let originalProposal = pendingProposal, originalConfirmationId = pendingConfirmationId
        var accumulator = AGUIRunAccumulator(threadId: threadId, runId: runId)
        do {
            recoveryInput = input
            try saveCheckpoint()
            for try await event in client.run(input) { try accumulator.receive(event) }
            try accumulator.finish()
            transcript.append(contentsOf: accumulator.messages.map { .init(id: $0.id, role: "assistant", content: $0.text) })
            for tool in accumulator.completedTools {
                let succeeded = await handleTool(tool)
                if tool.name == "refresh_practice", !succeeded { staleAfterSave = true }
            }
            if let proposal = accumulator.proposal {
                pendingProposal = proposal
                state = .awaitingConfirmation(proposal)
            } else {
                state = composer.isEmpty ? .idle : .readyToSend
                pendingConfirmationId = nil
                pendingProposal = nil
            }
            recoveryInput = nil
            try saveCheckpoint()
            return true
        } catch let error as AGUIError {
            assistantLog.error("Run \(runId.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            errorMessage = error.userMessage
            if error.closesProposal {
                // The server has settled it, so the card must not keep offering Confirm.
                pendingProposal = nil
                pendingConfirmationId = nil
                recoveryInput = nil
                try? saveCheckpoint()
            }
            state = pendingProposal.map(State.awaitingConfirmation) ?? .failed(error.userMessage)
            return false
        } catch {
            // A failed checkpoint write after a saved result must retain its retry identity in memory.
            if resume != nil, pendingProposal == nil {
                pendingProposal = originalProposal; pendingConfirmationId = originalConfirmationId
                recoveryInput = input
            }
            assistantLog.error("Run \(runId.uuidString, privacy: .public) was interrupted: \(error.localizedDescription, privacy: .public)")
            let message = "The assistant connection was interrupted. You can retry safely."
            errorMessage = message
            state = pendingProposal.map(State.awaitingConfirmation) ?? .failed(message)
            return false
        }
    }
}

private extension AGUIError {
    /// Server outcomes after which the open proposal can no longer be confirmed.
    var closesProposal: Bool {
        guard case .server(let code, _) = self else { return false }
        return ["PROPOSAL_EXPIRED", "PROPOSAL_REJECTED", "PROPOSAL_NOT_FOUND",
                "PROPOSAL_ALREADY_RESOLVED", "PROPOSAL_STALE"].contains(code)
    }

    var userMessage: String {
        switch self {
        case .server(_, let message), .unavailable(let message): message
        case .interrupted: "The assistant connection was interrupted. You can retry safely."
        case .eventTooLarge, .malformedEvent, .protocolViolation: "The assistant sent a response this app could not safely use."
        }
    }
}
