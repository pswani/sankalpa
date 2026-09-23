import Foundation

public enum VoiceInterpretationPhase: String, Equatable, Sendable {
    case idle
    case choosingSavedDraft
    case clarifying
    case reviewingSession
    case editingDeclaration
    case reviewingDeclaration
    case result
}

public struct VoiceInterpretationContext: Equatable, Sendable {
    public let nowDescription: String
    public let phase: VoiceInterpretationPhase
    public let draft: VoiceDeclarationDraft?
    public let clarification: Clarification?
    public let candidateTitles: [String]
    public let sessionProposalTitle: String?
    public let sessionProposalMoment: String?

    public init(
        nowDescription: String,
        phase: VoiceInterpretationPhase = .idle,
        draft: VoiceDeclarationDraft? = nil,
        clarification: Clarification? = nil,
        candidateTitles: [String] = [],
        sessionProposalTitle: String? = nil,
        sessionProposalMoment: String? = nil
    ) {
        self.nowDescription = nowDescription
        self.phase = phase
        self.draft = draft
        self.clarification = clarification
        self.candidateTitles = candidateTitles
        self.sessionProposalTitle = sessionProposalTitle
        self.sessionProposalMoment = sessionProposalMoment
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
