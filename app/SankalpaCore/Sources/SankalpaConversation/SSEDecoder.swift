import Foundation

public struct SSEDecoder: Sendable {
    private var buffer = Data()
    private let decoder = JSONDecoder()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [AGUI.Event] {
        buffer.append(bytes)
        if buffer.count > AGUI.maximumEventBytes { throw AGUIError.eventTooLarge }
        var events: [AGUI.Event] = []
        let separator = Data("\n\n".utf8)
        while let range = buffer.range(of: separator) {
            let frame = buffer[..<range.lowerBound]
            buffer.removeSubrange(..<range.upperBound)
            if let event = try decodeFrame(Data(frame)) { events.append(event) }
        }
        return events
    }

    public mutating func finish() throws -> [AGUI.Event] {
        guard buffer.isEmpty else { throw AGUIError.malformedEvent }
        return []
    }

    private func decodeFrame(_ frame: Data) throws -> AGUI.Event? {
        guard let text = String(data: frame, encoding: .utf8) else { throw AGUIError.malformedEvent }
        let dataLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("data:") }
            .map { line -> String in
                var value = String(line.dropFirst(5)); if value.first == " " { value.removeFirst() }
                return value
            }
        guard !dataLines.isEmpty, let data = dataLines.joined(separator: "\n").data(using: .utf8)
        else { return nil }
        let envelope = try decoder.decode(Envelope.self, from: data)
        return try envelope.event()
    }

    private struct Envelope: Decodable {
        let type: String; let threadId: UUID?; let runId: UUID?
        let messageId: UUID?; let toolCallId: UUID?; let toolCallName: String?
        let delta: String?; let outcome: JSONValue?; let code: String?; let message: String?

        func event() throws -> AGUI.Event {
            guard let threadId, let runId else {
                if type.hasPrefix("RUN_") || type.hasPrefix("TEXT_") || type.hasPrefix("TOOL_") {
                    throw AGUIError.malformedEvent
                }
                return .unsupported(type)
            }
            switch type {
            case "RUN_STARTED": return .runStarted(threadId: threadId, runId: runId)
            case "TEXT_MESSAGE_START": return .textStart(threadId: threadId, runId: runId, messageId: try required(messageId))
            case "TEXT_MESSAGE_CONTENT": return .textContent(threadId: threadId, runId: runId, messageId: try required(messageId), delta: try required(delta))
            case "TEXT_MESSAGE_END": return .textEnd(threadId: threadId, runId: runId, messageId: try required(messageId))
            case "TOOL_CALL_START": return .toolStart(threadId: threadId, runId: runId, toolCallId: try required(toolCallId), name: try required(toolCallName))
            case "TOOL_CALL_ARGS": return .toolArgs(threadId: threadId, runId: runId, toolCallId: try required(toolCallId), delta: try required(delta))
            case "TOOL_CALL_END": return .toolEnd(threadId: threadId, runId: runId, toolCallId: try required(toolCallId))
            case "RUN_FINISHED": return .runFinished(threadId: threadId, runId: runId, outcome: outcome)
            case "RUN_ERROR": return .runError(threadId: threadId, runId: runId, code: try required(code), message: try required(message))
            default: return .unsupported(type)
            }
        }
        private func required<T>(_ value: T?) throws -> T { guard let value else { throw AGUIError.malformedEvent }; return value }
    }
}
