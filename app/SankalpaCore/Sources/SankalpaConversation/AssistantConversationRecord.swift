import Foundation

public struct AssistantNegotiation: Codable, Equatable, Sendable {
    public var profile = AGUI.profile
    public var linked = false
    public var batchSessions = false
    public var beginCorrection = false
    public init(linked: Bool = false, batchSessions: Bool = false, beginCorrection: Bool = false) {
        self.linked = linked; self.batchSessions = batchSessions; self.beginCorrection = beginCorrection
    }
    public func supports(_ saved: Self) -> Bool {
        profile == saved.profile && (!saved.linked || linked) && (!saved.batchSessions || batchSessions)
            && (!saved.beginCorrection || beginCorrection)
    }
}

public struct AssistantRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case ordinary, confirm, cancel }
    public let kind: Kind
    public let input: AGUI.RunAgentInput
    public let negotiation: AssistantNegotiation
    public let negotiationInferred: Bool
    init(kind: Kind, input: AGUI.RunAgentInput, negotiation: AssistantNegotiation, negotiationInferred: Bool = false) {
        self.kind = kind; self.input = input; self.negotiation = negotiation; self.negotiationInferred = negotiationInferred
    }
    private enum CodingKeys: String, CodingKey { case kind, input, negotiation, negotiationInferred }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        kind = try fields.decode(Kind.self, forKey: .kind)
        input = try fields.decode(AGUI.RunAgentInput.self, forKey: .input)
        negotiation = try fields.decode(AssistantNegotiation.self, forKey: .negotiation)
        negotiationInferred = try fields.decodeIfPresent(Bool.self, forKey: .negotiationInferred) ?? false
    }
}

public struct AssistantConversationRecord: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion = 1
    public let serviceInstanceId: UUID
    public let id: UUID
    public var revision = 0
    public let createdAt: Date
    public var activityAt: Date
    public var transcript: [AGUI.Message] = []
    public var draft = ""
    public var proposal: AssistantProposal?
    public var confirmationId: UUID?
    public var lastCompletedRunId: UUID?
    public var request: AssistantRequest?
    public var queuedCorrection: String?
    public var editProposal: AssistantProposal?
    public var errorMessage: String?
    public var refreshNeeded = false
    public var imported = false

    public init(serviceInstanceId: UUID, id: UUID = UUID(), now: Date = Date()) {
        self.serviceInstanceId = serviceInstanceId; self.id = id
        self.createdAt = now; self.activityAt = now
    }
    public var title: String {
        guard let first = transcript.first(where: { $0.role == "user" }) else { return "New conversation" }
        return Self.abbreviate(first.content, limit: 60)
    }
    public var isEmpty: Bool {
        transcript.isEmpty && draft.isEmpty && proposal == nil && request == nil && !refreshNeeded && editProposal == nil
    }
    public var needsRecovery: Bool { request != nil || refreshNeeded }
    static func abbreviate(_ text: String, limit: Int) -> String {
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.count > limit ? String(normalized.prefix(max(0, limit - 1))) + "…" : normalized
    }
    func validate() throws {
        guard schemaVersion == 1, revision >= 0,
              Set(transcript.map(\.id)).count == transcript.count,
              transcript.allSatisfy({ ["user", "assistant"].contains($0.role) }) else {
            throw AssistantStorageError.invalidHistory
        }
        if let request {
            let input = request.input
            guard !request.negotiationInferred || imported else { throw AssistantStorageError.invalidHistory }
            guard input.threadId == id, input.state.isEmpty, input.context.isEmpty, input.forwardedProps.isEmpty,
                  input.messages.count <= AGUI.maximumMessages,
                  Set(input.messages.map(\.id)).count == input.messages.count,
                  input.messages.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.content.utf16.count <= 16_000 }),
                  input.tools == AGUI.Tool.supportedFrontendTools,
                  request.negotiation.profile == AGUI.profile,
                  (!request.negotiation.batchSessions || request.negotiation.linked),
                  (!request.negotiation.beginCorrection || request.negotiation.batchSessions),
                  try JSONEncoder().encode(input).count <= 262_144 else { throw AssistantStorageError.invalidHistory }
            switch request.kind {
            case .ordinary:
                guard input.resume == nil, input.messages.last?.role == "user" else { throw AssistantStorageError.invalidHistory }
            case .confirm, .cancel:
                guard input.messages.isEmpty, let resumes = input.resume, resumes.count == 1,
                      resumes[0].interruptId == proposal?.id else { throw AssistantStorageError.invalidHistory }
                if request.kind == .cancel {
                    guard resumes[0].status == "cancelled", resumes[0].payload == nil else { throw AssistantStorageError.invalidHistory }
                } else {
                    guard let confirmationId, resumes[0].status == "resolved",
                          resumes[0].payload == .object(["decision": .string("confirm"),
                              "confirmationId": .string(confirmationId.uuidString)]) else { throw AssistantStorageError.invalidHistory }
                }
            }
        }
    }
}

public struct AssistantConversationSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let revision: Int
    public let preview: String
    public let activityAt: Date
    public let createdAt: Date
    public let status: String?
    public let needsRecovery: Bool
    init(_ record: AssistantConversationRecord) {
        id = record.id; revision = record.revision; title = record.title; activityAt = record.activityAt; createdAt = record.createdAt
        preview = AssistantConversationRecord.abbreviate(record.transcript.last?.content ?? record.draft, limit: 100)
        needsRecovery = record.needsRecovery
        if record.needsRecovery { status = "Needs recovery" }
        else if record.proposal != nil { status = "Awaiting confirmation" }
        else if !record.draft.isEmpty { status = "Draft" }
        else { status = nil }
    }
}

public enum AssistantStorageError: Error, LocalizedError, Sendable {
    case invalidHistory, staleWrite, writeFailed
    public var errorDescription: String? {
        switch self {
        case .invalidHistory: "Assistant history could not be validated. Preserved files need recovery or a compatible app update before sending requests."
        case .staleWrite: "Assistant history changed before it could be saved. Reopen the conversation and try again."
        case .writeFailed: "Assistant changes could not be saved on this device. Check available storage and try again."
        }
    }
}
