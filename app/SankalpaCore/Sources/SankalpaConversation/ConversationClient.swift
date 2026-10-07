import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AGUIClient: Sendable {
    private let baseURL: URL
    private let bearerToken: String?
    private let session: URLSession
    private let encoder = JSONEncoder()

    public init(baseURL: URL, bearerToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL; self.bearerToken = bearerToken; self.session = session
    }

    public func run(_ input: AGUI.RunAgentInput) -> AsyncThrowingStream<AGUI.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appending(path: "/api/v1/assistant/runs")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let bearerToken, !bearerToken.isEmpty {
                        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try encoder.encode(input)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                          http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true
                    else { throw AGUIError.unavailable("The assistant endpoint refused the request.") }
                    var decoder = SSEDecoder(); var chunk = Data(); var sawTerminal = false
                    for try await byte in bytes {
                        try Task.checkCancellation(); chunk.append(byte)
                        if chunk.suffix(2) == Data("\n\n".utf8) {
                            for event in try decoder.append(chunk) {
                                if case .runFinished = event { sawTerminal = true }
                                if case .runError = event { sawTerminal = true }
                                continuation.yield(event)
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { _ = try decoder.append(chunk) }
                    _ = try decoder.finish()
                    guard sawTerminal else { throw AGUIError.interrupted }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct AGUIRunAccumulator: Sendable {
    public private(set) var messages: [AssistantMessage] = []
    public private(set) var completedTools: [FrontendToolCall] = []
    public private(set) var proposal: AssistantProposal?
    private let threadId: UUID; private let runId: UUID
    private var started = false; private var terminal = false
    private var message: (UUID, String)?; private var tool: (UUID, String, String)?
    private static let allowedTools = Set(["refresh_practice", "navigate_to_sankalpa", "open_sankalpa_list"])

    public init(threadId: UUID, runId: UUID) { self.threadId = threadId; self.runId = runId }

    public mutating func receive(_ event: AGUI.Event) throws {
        if case .unsupported = event { return }
        let correlation = event.correlation
        guard correlation.0 == threadId, correlation.1 == runId, !terminal else {
            throw AGUIError.protocolViolation("Wrong or completed run correlation")
        }
        if !started {
            guard case .runStarted = event else { throw AGUIError.protocolViolation("RUN_STARTED must be first") }
            started = true; return
        }
        switch event {
        case .runStarted: throw AGUIError.protocolViolation("Duplicate RUN_STARTED")
        case .textStart(_, _, let id):
            guard message == nil else { throw AGUIError.protocolViolation("Nested message") }
            message = (id, "")
        case .textContent(_, _, let id, let delta):
            guard message?.0 == id, !delta.isEmpty else { throw AGUIError.protocolViolation("Invalid message delta") }
            message!.1.append(delta)
        case .textEnd(_, _, let id):
            guard let current = message, current.0 == id else { throw AGUIError.protocolViolation("Unmatched message end") }
            messages.append(AssistantMessage(id: id, text: current.1)); message = nil
        case .toolStart(_, _, let id, let name):
            guard tool == nil else { throw AGUIError.protocolViolation("Nested tool") }
            tool = (id, name, "")
        case .toolArgs(_, _, let id, let delta):
            guard tool?.0 == id else { throw AGUIError.protocolViolation("Unmatched tool args") }
            tool!.2.append(delta)
        case .toolEnd(_, _, let id):
            guard let current = tool, current.0 == id else { throw AGUIError.protocolViolation("Unmatched tool end") }
            guard Self.allowedTools.contains(current.1),
                  let data = current.2.data(using: .utf8),
                  let arguments = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object = arguments
            else { throw AGUIError.protocolViolation("Unsafe or malformed frontend tool") }
            completedTools.append(FrontendToolCall(id: id, name: current.1, arguments: arguments)); tool = nil
        case .runFinished(_, _, let outcome):
            guard message == nil, tool == nil else { throw AGUIError.protocolViolation("Incomplete content at terminal event") }
            proposal = try outcome.flatMap(AssistantProposal.init(outcome:)); terminal = true
        case .runError(_, _, let code, let text): terminal = true; throw AGUIError.server(code: code, message: text)
        case .unsupported: break
        }
    }

    public mutating func finish() throws {
        guard started, terminal else { throw AGUIError.interrupted }
    }
}

private extension AGUI.Event {
    var correlation: (UUID?, UUID?) {
        switch self {
        case .runStarted(let t, let r), .textStart(let t, let r, _),
             .textContent(let t, let r, _, _), .textEnd(let t, let r, _),
             .toolStart(let t, let r, _, _), .toolArgs(let t, let r, _, _),
             .toolEnd(let t, let r, _), .runFinished(let t, let r, _),
             .runError(let t, let r, _, _): return (t, r)
        case .unsupported: return (nil, nil)
        }
    }
}
