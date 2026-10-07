import Foundation

public enum AGUI {
    public static let profile = "ag-ui-sankalpa/1"
    public static let maximumEventBytes = 65_536
    public static let maximumMessages = 20

    public struct Message: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let role: String
        public let content: String
        public init(id: UUID = UUID(), role: String, content: String) {
            self.id = id; self.role = role; self.content = content
        }
    }

    public struct Tool: Codable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let parameters: JSONValue
        public init(name: String, description: String, parameters: JSONValue) {
            self.name = name; self.description = description; self.parameters = parameters
        }
    }

    public struct Resume: Codable, Equatable, Sendable {
        public let interruptId: UUID
        public let status: String
        public let payload: JSONValue?
        public init(interruptId: UUID, status: String, payload: JSONValue? = nil) {
            self.interruptId = interruptId; self.status = status; self.payload = payload
        }
    }

    public struct RunAgentInput: Codable, Equatable, Sendable {
        public let threadId: UUID
        public let runId: UUID
        public let parentRunId: UUID?
        public let state: [String: JSONValue]
        public let messages: [Message]
        public let tools: [Tool]
        public let context: [JSONValue]
        public let forwardedProps: [String: JSONValue]
        public let resume: [Resume]?

        public init(threadId: UUID, runId: UUID, parentRunId: UUID? = nil,
                    messages: [Message], tools: [Tool], resume: [Resume]? = nil) {
            self.threadId = threadId; self.runId = runId; self.parentRunId = parentRunId
            self.state = [:]; self.messages = Array(messages.suffix(Self.messageLimit))
            self.tools = tools; self.context = []; self.forwardedProps = [:]; self.resume = resume
        }
        private static let messageLimit = AGUI.maximumMessages
    }

    public enum Event: Equatable, Sendable {
        case runStarted(threadId: UUID, runId: UUID)
        case textStart(threadId: UUID, runId: UUID, messageId: UUID)
        case textContent(threadId: UUID, runId: UUID, messageId: UUID, delta: String)
        case textEnd(threadId: UUID, runId: UUID, messageId: UUID)
        case toolStart(threadId: UUID, runId: UUID, toolCallId: UUID, name: String)
        case toolArgs(threadId: UUID, runId: UUID, toolCallId: UUID, delta: String)
        case toolEnd(threadId: UUID, runId: UUID, toolCallId: UUID)
        case runFinished(threadId: UUID, runId: UUID, outcome: JSONValue?)
        case runError(threadId: UUID, runId: UUID, code: String, message: String)
        case unsupported(String)
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported JSON") }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v); case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v); case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v); case .null: try value.encodeNil()
        }
    }
}

public enum AGUIError: Error, Equatable, Sendable {
    case malformedEvent, eventTooLarge, protocolViolation(String), interrupted
    case server(code: String, message: String), unavailable(String)
}
