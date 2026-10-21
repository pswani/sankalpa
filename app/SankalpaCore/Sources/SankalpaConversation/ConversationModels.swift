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

public struct AssistantProposal: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case logSession = "LOG_SESSION", declareSankalpa = "DECLARE_SANKALPA"
        case logSessions = "LOG_SESSIONS", unsupported = "UNSUPPORTED"
    }
    public let id: UUID
    public let kind: Kind
    public let expiresAt: String
    public let metadata: [String: JSONValue]

    public var canConfirm: Bool { kind != .unsupported }
    public var batch: [String: JSONValue] {
        if case .object(let value)? = metadata["batch"] { return value }
        return [:]
    }
    public var newSessionCount: Int {
        if case .array(let entries)? = batch["entries"] { return entries.count }
        return 0
    }

    private enum CodingKeys: String, CodingKey { case id, kind, expiresAt, metadata }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let id = try fields.decode(UUID.self, forKey: .id)
        let expiry = try fields.decode(String.self, forKey: .expiresAt)
        let metadata = try fields.decode([String: JSONValue].self, forKey: .metadata)
        // Persisted metadata goes through exactly the same validation as the wire preview.
        guard let proposal = try AssistantProposal(outcome: .object([
            "type": .string("interrupt"), "interrupts": .array([.object([
                "id": .string(id.uuidString), "expiresAt": .string(expiry), "metadata": .object(metadata)
            ])])
        ])) else { throw AGUIError.protocolViolation("Invalid saved proposal") }
        self = proposal
    }

    init?(outcome: JSONValue) throws {
        guard case .object(let root) = outcome,
              root["type"] == .string("interrupt"),
              case .array(let interrupts)? = root["interrupts"], interrupts.count == 1,
              case .object(let item) = interrupts[0],
              case .string(let idText)? = item["id"], let id = UUID(uuidString: idText),
              case .string(let expiresAt)? = item["expiresAt"],
              case .object(let metadata)? = item["metadata"],
              case .string(let kindText)? = metadata["proposalType"]
        else { return nil }
        var kind = Kind(rawValue: kindText) ?? .unsupported
        let version = metadata["proposalVersion"]
        if kind == .logSessions {
            if version != .number(2) && version != .number(3) { kind = .unsupported }
        } else if version != .number(1) { kind = .unsupported }
        if kind == .logSessions {
            guard case .object(let batch)? = metadata["batch"],
                  case .array(let entries)? = batch["entries"], (1...30).contains(entries.count),
                  case .array(let skipped)? = batch["skippedDays"],
                  case .array? = batch["repeatWarnings"],
                  case .number(let requested)? = batch["requestedCount"], requested >= 1, requested <= 30, requested.rounded() == requested,
                  Int(requested) == entries.count + skipped.count,
                  case .object? = batch["plan"], case .string? = batch["timezone"],
                  case .string(let owner)? = metadata["sankalpaId"], UUID(uuidString: owner) != nil,
                  case .string? = metadata["sankalpaTitle"]
            else { throw AGUIError.protocolViolation("Incomplete batch preview") }
            if version == .number(3) {
                let hasAdjustment: Bool = {
                    guard case .object(let adjustment)? = batch["beginAdjustment"],
                          case .string(let id)? = adjustment["id"], UUID(uuidString: id) != nil,
                          case .string(let previous)? = adjustment["previousEffectiveAt"], !previous.isEmpty,
                          case .string(let corrected)? = adjustment["correctedEffectiveAt"], !corrected.isEmpty else { return false }
                    return true
                }()
                let hasSuggestedTime: Bool = {
                    guard case .object(let plan)? = batch["plan"] else { return false }
                    return plan["recordingTimeSuggested"] == .bool(true)
                }()
                guard hasAdjustment || hasSuggestedTime else { throw AGUIError.protocolViolation("Missing history repair details") }
            }
            var ids = Set<UUID>()
            for entry in entries {
                guard case .object(let fields) = entry,
                      case .string(let id)? = fields["sessionId"], let uuid = UUID(uuidString: id),
                      ids.insert(uuid).inserted,
                      case .string(let time)? = fields["occurredAt"], !time.isEmpty
                else { throw AGUIError.protocolViolation("Invalid batch entry") }
            }
            for day in skipped {
                guard case .object(let fields) = day, case .string? = fields["date"],
                      case .array(let ids)? = fields["contributionIds"], !ids.isEmpty
                else { throw AGUIError.protocolViolation("Invalid skipped day") }
            }
        }
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
