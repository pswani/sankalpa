import Foundation
import SankalpaCore

public enum VoiceUnavailableReason: Equatable, Sendable {
    case microphonePermissionNeeded
    case microphoneDenied
    case unsupportedOS
    case unsupportedLocale
    case speechAssetsNeeded
    case languageModelDisabled
    case languageModelNotReady

    public var message: String {
        switch self {
        case .microphonePermissionNeeded: return "Microphone access is needed to listen."
        case .microphoneDenied: return "Microphone access is off. You can enable it in Settings."
        case .unsupportedOS: return "Voice requires iOS 27 or later."
        case .unsupportedLocale: return "Voice is not available for this language yet."
        case .speechAssetsNeeded: return "Speech recognition needs to finish downloading."
        case .languageModelDisabled: return "Apple Intelligence must be enabled for voice interpretation."
        case .languageModelNotReady: return "The on-device language model is not ready yet."
        }
    }
}

public struct VoiceConversationContext: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case undecided, session, declaration }

    public var mode: Mode
    public var draft: VoiceDeclarationDraft?
    public var sankalpaReference: String?
    public var sessionDay: CalendarDay?
    public var sessionMoment: CalendarMoment?
    public var candidates: [VoiceSankalpaReference]

    public init(
        mode: Mode = .undecided,
        draft: VoiceDeclarationDraft? = nil,
        sankalpaReference: String? = nil,
        sessionDay: CalendarDay? = nil,
        sessionMoment: CalendarMoment? = nil,
        candidates: [VoiceSankalpaReference] = []
    ) {
        self.mode = mode
        self.draft = draft
        self.sankalpaReference = sankalpaReference
        self.sessionDay = sessionDay
        self.sessionMoment = sessionMoment
        self.candidates = candidates
    }
}

public enum VoiceConversationState: Equatable, Sendable {
    case unavailable(VoiceUnavailableReason)
    case idle(savedDraft: VoiceDeclarationDraft?)
    case choosingSavedDraft(VoiceDeclarationDraft)
    case listening(VoiceConversationContext)
    case interpreting(VoiceConversationContext, transcript: String)
    case clarifying(VoiceConversationContext, question: Clarification)
    case reviewingSession(VoiceSessionProposal)
    case editingDeclaration(VoiceDeclarationDraft, nextQuestion: Clarification?)
    case reviewingDeclaration(VoiceDeclarationProposal)
    case executing(ProposalID)
    case result(VoiceResult, savedDraft: VoiceDeclarationDraft?)

    public var savedDraft: VoiceDeclarationDraft? {
        switch self {
        case .idle(let draft), .result(_, let draft): return draft
        case .choosingSavedDraft(let draft), .editingDeclaration(let draft, _): return draft
        case .reviewingDeclaration(let proposal): return proposal.draft
        case .listening(let context), .interpreting(let context, _), .clarifying(let context, _):
            return context.draft
        default: return nil
        }
    }
}

public enum VoiceEffect: Equatable, Sendable {
    case saveDraft(VoiceDeclarationDraft)
    case discardDraft(VoiceDeclarationDraft)
    case logSession(VoiceSessionProposal)
    case declare(VoiceDeclarationProposal)
}

public struct VoiceReduction: Equatable, Sendable {
    public let state: VoiceConversationState
    public let effect: VoiceEffect?

    public init(state: VoiceConversationState, effect: VoiceEffect? = nil) {
        self.state = state
        self.effect = effect
    }
}
