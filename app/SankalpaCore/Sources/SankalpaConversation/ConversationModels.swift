import Foundation

public struct AssistantMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public init(id: UUID = UUID(), text: String) { self.id = id; self.text = text }
}

public struct FrontendToolCall: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let arguments: JSONValue
}

public struct AssistantProposal: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case logSession = "LOG_SESSION", declareSankalpa = "DECLARE_SANKALPA" }
    public let id: UUID
    public let kind: Kind
    public let expiresAt: String
    public let metadata: [String: JSONValue]

    init?(outcome: JSONValue) throws {
        guard case .object(let root) = outcome,
              root["type"] == .string("interrupt"),
              case .array(let interrupts)? = root["interrupts"], interrupts.count == 1,
              case .object(let item) = interrupts[0],
              case .string(let idText)? = item["id"], let id = UUID(uuidString: idText),
              case .string(let expiresAt)? = item["expiresAt"],
              case .object(let metadata)? = item["metadata"],
              case .string(let kindText)? = metadata["proposalType"], let kind = Kind(rawValue: kindText)
        else { return nil }
        self.id = id; self.kind = kind; self.expiresAt = expiresAt; self.metadata = metadata
    }
}

public extension AGUI.Tool {
    static let refreshPractice = AGUI.Tool(
        name: "refresh_practice",
        description: "Refresh authoritative practice after a saved change.",
        parameters: .object(["type": .string("object")]))
    static let navigateToSankalpa = AGUI.Tool(
        name: "navigate_to_sankalpa", description: "Open one Sankalpa.",
        parameters: .object(["type": .string("object")]))
    static let openSankalpaList = AGUI.Tool(
        name: "open_sankalpa_list", description: "Open the Sankalpa list.",
        parameters: .object(["type": .string("object")]))
    static let supportedFrontendTools = [refreshPractice, navigateToSankalpa, openSankalpaList]
}
