import Foundation
import Observation
import SankalpaCore
import SankalpaVoice

@MainActor
@Observable
final class VoiceAssistantModel {
    private let gateway: any VoiceCommandGateway
    private let draftStore: any VoiceDraftStoring
    private let reducer = VoiceConversationReducer()
    private let readiness = VoiceReadiness()

    private var transcriber: (any VoiceTranscribing)?
    private var listeningTask: Task<Void, Never>?
    private var turnSourceState: VoiceConversationState?
    private var persistedRevision: Int?
    private var interpretationID = UUID()

    private(set) var state: VoiceConversationState
    private(set) var isListening = false
    private(set) var isWorking = false
    var transcript = ""
    var statusMessage: String?

    init(
        gateway: any VoiceCommandGateway,
        draftStore: any VoiceDraftStoring = VoiceDraftStore()
    ) {
        self.gateway = gateway
        self.draftStore = draftStore
        let loaded = draftStore.load()
        self.persistedRevision = loaded.draft?.revision
        if let warning = loaded.warning {
            self.state = .result(.notSaved(warning), savedDraft: nil)
        } else if let draft = loaded.draft {
            self.state = .idle(savedDraft: draft)
        } else {
            self.state = .idle(savedDraft: nil)
        }
    }

    var hasSavedDraft: Bool { state.savedDraft != nil }
    var isExecuting: Bool {
        if case .executing = state { return true }
        return false
    }

    var prompt: String {
        switch state {
        case .unavailable(let reason): return reason.message
        case .idle(let draft):
            return draft == nil
                ? "Log a session or prepare a new Sankalpa in your own words."
                : "You have an unfinished Sankalpa draft. Resume it, discard it, or log a session."
        case .choosingSavedDraft: return "You have an unfinished Sankalpa draft."
        case .listening: return "Listening…"
        case .interpreting: return "Understanding what you said…"
        case .clarifying(_, let question): return question.question
        case .reviewingSession: return "Review this session before logging it."
        case .editingDeclaration(_, let question):
            return question?.question ?? "Continue describing your Sankalpa."
        case .reviewingDeclaration: return "Review this Sankalpa before declaring it."
        case .executing: return "Saving…"
        case .result(let result, _): return result.message
        }
    }

    func startListening() async {
        guard !isListening, !isWorking else { return }
        let activeID = beginOperation()
        statusMessage = nil
        var readinessStatus = await readiness.status()
        guard activeID == interpretationID else { return }
        if readinessStatus == .unavailable(.microphonePermissionNeeded) {
            let permissionGranted = await readiness.requestMicrophonePermission()
            guard activeID == interpretationID else { return }
            guard permissionGranted else {
                state = .unavailable(.microphoneDenied)
                return
            }
            readinessStatus = await readiness.status()
            guard activeID == interpretationID else { return }
        }
        guard readinessStatus == .ready else {
            if case .unavailable(let reason) = readinessStatus { state = .unavailable(reason) }
            return
        }
        guard #available(iOS 27.0, *) else {
            state = .unavailable(.unsupportedOS)
            return
        }

        let source = state
        let context = conversationContext(from: source)
        let transcriber = AppleSpeechTranscriber()
        self.transcriber = transcriber
        self.turnSourceState = source
        transcript = ""
        state = .listening(context)
        isListening = true
        do {
            let stream = try await transcriber.start(locale: .current)
            guard activeID == interpretationID else {
                await transcriber.cancel()
                return
            }
            listeningTask = Task { [weak self] in
                do {
                    for try await update in stream {
                        guard let self, self.interpretationID == activeID else { return }
                        self.transcript = update.text
                    }
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          self.interpretationID == activeID else { return }
                    await transcriber.cancel()
                    guard self.interpretationID == activeID else { return }
                    self.isListening = false
                    self.transcriber = nil
                    self.state = source
                    self.statusMessage = "Speech could not be transcribed. You can retry or type a correction."
                }
            }
        } catch {
            guard activeID == interpretationID else { return }
            await transcriber.cancel()
            guard activeID == interpretationID else { return }
            isListening = false
            self.transcriber = nil
            state = source
            statusMessage = "Speech could not start. Try again."
        }
    }

    func installSpeechAssets() async {
        guard #available(iOS 27.0, *) else { return }
        let activeID = beginOperation()
        isWorking = true
        statusMessage = "Downloading speech recognition…"
        defer {
            if activeID == interpretationID { isWorking = false }
        }
        do {
            try await readiness.installSpeechAssets()
            guard activeID == interpretationID else { return }
            statusMessage = "Speech recognition is ready."
            state = .idle(savedDraft: state.savedDraft)
        } catch {
            guard activeID == interpretationID else { return }
            statusMessage = "Speech recognition could not be downloaded. Try again when connected."
        }
    }

    func stopListening() async {
        guard isListening, let transcriber else { return }
        let activeID = interpretationID
        isWorking = true
        do {
            let final = try await transcriber.finish()
            guard activeID == interpretationID else { return }
            self.transcript = final
            isListening = false
            self.transcriber = nil
            await interpret(final, operationID: activeID)
        } catch {
            guard activeID == interpretationID else { return }
            await transcriber.cancel()
            guard activeID == interpretationID else { return }
            isListening = false
            self.transcriber = nil
            statusMessage = "No final words were recognized. You can retry or type what you said."
        }
        if activeID == interpretationID { isWorking = false }
    }

    func applyCorrection() async {
        let corrected = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, !isListening, !isWorking else { return }
        let activeID = beginOperation()
        turnSourceState = sourceForCorrection()
        await interpret(corrected, operationID: activeID)
    }

    func confirm() async {
        guard !isListening, !isWorking else { return }
        let activeID = beginOperation()
        isWorking = true
        defer {
            if activeID == interpretationID { isWorking = false }
        }
        await apply(
            InterpretedTurn(intent: .confirm),
            to: state,
            operationID: activeID
        )
    }

    func resumeDraft() async {
        let activeID = beginOperation()
        await apply(InterpretedTurn(intent: .resumeDraft), to: state, operationID: activeID)
    }

    func discardDraft() async {
        let activeID = beginOperation()
        await apply(InterpretedTurn(intent: .discardDraft), to: state, operationID: activeID)
    }

    func cancel() async {
        // Confirmation is the commit point. Once its command is in flight, let the authoritative
        // outcome finish instead of hiding a server acceptance behind a local cancellation.
        guard !isExecuting else { return }
        interpretationID = UUID()
        listeningTask?.cancel()
        await transcriber?.cancel()
        transcriber = nil
        isListening = false
        isWorking = false
        let reduction = reducer.reduce(
            state,
            turn: InterpretedTurn(intent: .cancel),
            practice: gateway.voicePracticeSnapshot,
            now: gateway.voiceNow
        )
        state = reduction.state
    }

    private func interpret(_ text: String, operationID activeInterpretationID: UUID) async {
        guard #available(iOS 27.0, *) else {
            state = .unavailable(.unsupportedOS)
            return
        }
        isWorking = true
        let source = turnSourceState ?? state
        let context = conversationContext(from: source)
        state = .interpreting(context, transcript: text)
        do {
            let interpreter = try FoundationModelVoiceInterpreter()
            let turn = try await interpreter.interpret(
                text,
                context: VoiceInterpretationContext(
                    nowDescription: Self.describe(gateway.voiceNow),
                    phase: interpretationPhase(from: source),
                    draft: context.draft,
                    clarification: clarification(from: source),
                    candidateTitles: context.candidates.map(\.title),
                    sessionProposalTitle: context.mode == .session
                        ? context.sankalpaReference : nil,
                    sessionProposalMoment: context.mode == .session
                        ? context.sessionMoment.map(Self.describe) : nil
                )
            )
            guard activeInterpretationID == interpretationID else { return }
            await apply(turn, to: source, operationID: activeInterpretationID)
        } catch {
            guard activeInterpretationID == interpretationID else { return }
            state = source
            statusMessage = "Those words could not be interpreted. Edit the transcript or try again."
        }
        if activeInterpretationID == interpretationID {
            isWorking = false
        }
    }

    private func apply(
        _ turn: InterpretedTurn,
        to source: VoiceConversationState,
        operationID activeID: UUID
    ) async {
        guard activeID == interpretationID else { return }
        let reduction = reducer.reduce(
            source,
            turn: turn,
            practice: gateway.voicePracticeSnapshot,
            now: gateway.voiceNow
        )
        state = reduction.state
        guard let effect = reduction.effect else { return }
        await perform(effect, operationID: activeID)
    }

    private func perform(_ effect: VoiceEffect, operationID activeID: UUID) async {
        guard activeID == interpretationID else { return }
        switch effect {
        case .saveDraft(let draft):
            do {
                try draftStore.save(draft)
                persistedRevision = draft.revision
            } catch {
                state = .result(.notSaved("This draft could not be saved."), savedDraft: draft)
            }
        case .discardDraft(let draft):
            do {
                try draftStore.discard()
                persistedRevision = nil
                state = .idle(savedDraft: nil)
            } catch {
                state = .result(.notSaved("This draft could not be discarded."), savedDraft: draft)
            }
        case .logSession(let proposal):
            let result = await gateway.logSessionForVoice(
                proposal.sankalpaID,
                occurredAt: proposal.occurredAt
            )
            guard activeID == interpretationID else { return }
            switch result {
            case .acceptedByService:
                state = .result(.sessionAccepted, savedDraft: proposal.savedDraft)
            case .pendingOnDevice:
                state = .result(.sessionPending, savedDraft: proposal.savedDraft)
            case .refused(let message):
                state = .result(.refused(message), savedDraft: proposal.savedDraft)
            case .notSaved(let message):
                state = .result(.notSaved(message), savedDraft: proposal.savedDraft)
            }
        case .declare(let proposal):
            let result = await gateway.declareForVoice(
                proposal.declaration,
                commandID: proposal.draft.id
            )
            guard activeID == interpretationID else { return }
            switch result {
            case .acceptedByService:
                do {
                    try draftStore.discard()
                    persistedRevision = nil
                    state = .result(.declarationAccepted, savedDraft: nil)
                } catch {
                    state = .result(
                        .declarationAcceptedWithDraftCleanupWarning,
                        savedDraft: proposal.draft
                    )
                }
            case .serviceUnavailable:
                let message = persistedRevision == proposal.draft.revision
                    ? "Draft saved. This Sankalpa has not been declared."
                    : "This draft could not be saved."
                state = .result(.draftOnly(message), savedDraft: proposal.draft)
            case .refused(let message):
                state = .result(.refused(message), savedDraft: proposal.draft)
            case .notSaved(let message):
                state = .result(.notSaved(message), savedDraft: proposal.draft)
            }
        }
    }

    private func beginOperation() -> UUID {
        let id = UUID()
        interpretationID = id
        return id
    }

    private func conversationContext(from state: VoiceConversationState) -> VoiceConversationContext {
        switch state {
        case .listening(let context), .interpreting(let context, _), .clarifying(let context, _):
            return context
        case .editingDeclaration(let draft, _):
            return VoiceConversationContext(mode: .declaration, draft: draft)
        case .reviewingDeclaration(let proposal):
            return VoiceConversationContext(mode: .declaration, draft: proposal.draft)
        case .reviewingSession(let proposal):
            return VoiceConversationContext(
                mode: .session,
                draft: proposal.savedDraft,
                sankalpaReference: proposal.title,
                sessionDay: proposal.occurredAt.day,
                sessionMoment: proposal.occurredAt
            )
        default:
            return VoiceConversationContext(draft: state.savedDraft)
        }
    }

    private func clarification(from state: VoiceConversationState) -> Clarification? {
        switch state {
        case .clarifying(_, let question): return question
        case .editingDeclaration(_, let question): return question
        default: return nil
        }
    }

    private func interpretationPhase(
        from state: VoiceConversationState
    ) -> VoiceInterpretationPhase {
        switch state {
        case .choosingSavedDraft: return .choosingSavedDraft
        case .clarifying: return .clarifying
        case .reviewingSession: return .reviewingSession
        case .editingDeclaration: return .editingDeclaration
        case .reviewingDeclaration: return .reviewingDeclaration
        case .result: return .result
        default: return .idle
        }
    }

    private func sourceForCorrection() -> VoiceConversationState {
        switch state {
        case .interpreting(let context, _), .listening(let context): return .listening(context)
        default: return state
        }
    }

    private static func describe(_ moment: CalendarMoment) -> String {
        String(
            format: "%04d-%02d-%02d %02d:%02d",
            moment.day.year, moment.day.month, moment.day.day, moment.hour, moment.minute
        )
    }
}
