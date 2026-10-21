import Foundation
import Observation

public protocol AssistantRunClient: Sendable {
    func run(_ input: AGUI.RunAgentInput) -> AsyncThrowingStream<AGUI.Event, Error>
}
extension AGUIClient: AssistantRunClient {}

/// One conversation's presentation state. The controller/store own request lifetime and writes.
@MainActor @Observable
public final class AssistantSession {
    public internal(set) var record: AssistantConversationRecord
    public internal(set) var composer: String
    public internal(set) var isBusy = false
    init(record: AssistantConversationRecord) { self.record = record; composer = record.draft }
    public var threadId: UUID { record.id }
    public var transcript: [AGUI.Message] { record.transcript }
    public var errorMessage: String? { record.errorMessage }
    public var staleAfterSave: Bool { record.refreshNeeded }
    public var proposal: AssistantProposal? { record.proposal }
    public var title: String { record.title }
    public var needsRecovery: Bool { record.needsRecovery }
    public func proposalExpired(at now: Date = Date()) -> Bool {
        guard let proposal else { return false }
        guard let date = ISO8601DateFormatter().date(from: proposal.expiresAt) else { return true }
        return now >= date
    }
}
