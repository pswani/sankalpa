import Foundation

public struct VoiceInterpretationContext: Equatable, Sendable {
    public let nowDescription: String
    public let draft: VoiceDeclarationDraft?
    public let clarification: Clarification?
    public let candidateTitles: [String]

    public init(
        nowDescription: String,
        draft: VoiceDeclarationDraft? = nil,
        clarification: Clarification? = nil,
        candidateTitles: [String] = []
    ) {
        self.nowDescription = nowDescription
        self.draft = draft
        self.clarification = clarification
        self.candidateTitles = candidateTitles
    }
}

public protocol VoiceInterpreting: Sendable {
    func interpret(
        _ utterance: String,
        context: VoiceInterpretationContext
    ) async throws -> InterpretedTurn
}

public enum VoiceInterpretationError: Error, Equatable, Sendable {
    case unavailable
    case invalidResponse(String)
}
