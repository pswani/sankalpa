import Foundation
import Observation

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

    public init(threadId: UUID = UUID(), client: any AssistantRunClient,
                handleTool: @escaping @MainActor @Sendable (FrontendToolCall) async -> Bool = { _ in true }) {
        self.threadId = threadId; self.client = client; self.handleTool = handleTool
    }

    public var isBusy: Bool {
        switch state { case .running, .resolvingProposal: true; default: false }
    }

    public func send() async {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
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
        guard case .awaitingConfirmation(let proposal) = state else { return }
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

    @discardableResult
    private func perform(messages: [AGUI.Message], resume: [AGUI.Resume]?, reuseRunId: UUID?) async -> Bool {
        let runId = reuseRunId ?? UUID(); let parentRunId = lastRunId; lastRunId = runId
        state = resume == nil ? .running(runId) : .resolvingProposal(runId)
        errorMessage = nil
        let input = AGUI.RunAgentInput(threadId: threadId, runId: runId,
            parentRunId: parentRunId, messages: messages,
            tools: AGUI.Tool.supportedFrontendTools, resume: resume)
        var accumulator = AGUIRunAccumulator(threadId: threadId, runId: runId)
        do {
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
            return true
        } catch let error as AGUIError {
            errorMessage = error.userMessage
            state = pendingProposal.map(State.awaitingConfirmation) ?? .failed(error.userMessage)
            return false
        } catch {
            let message = "The assistant connection was interrupted. You can retry safely."
            errorMessage = message
            state = pendingProposal.map(State.awaitingConfirmation) ?? .failed(message)
            return false
        }
    }
}

private extension AGUIError {
    var userMessage: String {
        switch self {
        case .server(_, let message), .unavailable(let message): message
        case .interrupted: "The assistant connection was interrupted. You can retry safely."
        case .eventTooLarge, .malformedEvent, .protocolViolation: "The assistant sent a response this app could not safely use."
        }
    }
}
