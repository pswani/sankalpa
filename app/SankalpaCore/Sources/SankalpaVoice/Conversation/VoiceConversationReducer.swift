import Foundation
import SankalpaCore

/// All conversational authority lives here. Generated output can propose values, but only this
/// reducer can create an executable effect.
public struct VoiceConversationReducer: Sendable {
    private let resolver = SankalpaReferenceResolver()

    public init() {}

    public func reduce(
        _ state: VoiceConversationState,
        turn: InterpretedTurn,
        practice: VoicePracticeSnapshot,
        now: CalendarMoment
    ) -> VoiceReduction {
        if turn.intent == .cancel {
            return VoiceReduction(state: .idle(savedDraft: state.savedDraft))
        }

        switch state {
        case .choosingSavedDraft(let draft):
            return chooseSavedDraft(draft, turn: turn, now: now)
        case .reviewingSession(let proposal):
            return reduceSessionReview(proposal, turn: turn, practice: practice, now: now)
        case .reviewingDeclaration(let proposal):
            return reduceDeclaration(draft: proposal.draft, turn: turn, now: now)
        case .editingDeclaration(let draft, _):
            return reduceDeclaration(draft: draft, turn: turn, now: now)
        case .clarifying(let context, _), .listening(let context), .interpreting(let context, _):
            return reduceContext(context, turn: turn, practice: practice, now: now)
        case .idle(let draft), .result(_, let draft):
            let context = VoiceConversationContext(draft: draft)
            return reduceContext(context, turn: turn, practice: practice, now: now)
        case .executing, .unavailable:
            return VoiceReduction(state: state)
        }
    }

    public func start(from state: VoiceConversationState) -> VoiceConversationState {
        if let draft = state.savedDraft { return .choosingSavedDraft(draft) }
        return .listening(VoiceConversationContext())
    }

    private func chooseSavedDraft(
        _ draft: VoiceDeclarationDraft,
        turn: InterpretedTurn,
        now: CalendarMoment
    ) -> VoiceReduction {
        switch turn.intent {
        case .resumeDraft:
            if let proposal = proposal(from: draft, now: now) {
                return VoiceReduction(state: .reviewingDeclaration(proposal))
            }
            return VoiceReduction(
                state: .editingDeclaration(draft, nextQuestion: nextQuestion(for: draft))
            )
        case .discardDraft:
            return VoiceReduction(state: .choosingSavedDraft(draft), effect: .discardDraft(draft))
        default:
            return VoiceReduction(state: .choosingSavedDraft(draft))
        }
    }

    private func reduceContext(
        _ context: VoiceConversationContext,
        turn: InterpretedTurn,
        practice: VoicePracticeSnapshot,
        now: CalendarMoment
    ) -> VoiceReduction {
        switch turn.intent {
        case .logSession:
            return reduceSession(context: context, turn: turn, practice: practice, now: now)
        case .updateDeclaration:
            return reduceDeclaration(
                draft: context.draft ?? VoiceDeclarationDraft(),
                turn: turn,
                now: now
            )
        case .unsupported:
            return VoiceReduction(
                state: .result(
                    .notSaved("Voice currently supports logging one session or preparing one new Sankalpa."),
                    savedDraft: context.draft
                )
            )
        default:
            return VoiceReduction(state: .listening(context))
        }
    }

    private func reduceSessionReview(
        _ proposal: VoiceSessionProposal,
        turn: InterpretedTurn,
        practice: VoicePracticeSnapshot,
        now: CalendarMoment
    ) -> VoiceReduction {
        if turn.intent == .confirm {
            return VoiceReduction(state: .executing(proposal.id), effect: .logSession(proposal))
        }
        if turn.intent == .logSession {
            let context = VoiceConversationContext(
                mode: .session,
                sankalpaReference: proposal.title,
                sessionMoment: proposal.occurredAt
            )
            return reduceSession(context: context, turn: turn, practice: practice, now: now)
        }
        return VoiceReduction(state: .reviewingSession(proposal))
    }

    private func reduceSession(
        context: VoiceConversationContext,
        turn: InterpretedTurn,
        practice: VoicePracticeSnapshot,
        now: CalendarMoment
    ) -> VoiceReduction {
        var next = context
        next.mode = .session
        if let reference = turn.sankalpaReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty {
            next.sankalpaReference = reference
        }
        if let year = turn.year, let month = turn.month, let day = turn.day,
           let parsed = CalendarDay(year: year, month: month, day: day) {
            next.sessionDay = parsed
        }

        switch sessionMoment(
            turn: turn,
            existingDay: next.sessionDay,
            existing: context.sessionMoment,
            now: now
        ) {
        case .value(let moment): next.sessionMoment = moment
        case .clarify(let clarification):
            return VoiceReduction(state: .clarifying(next, question: clarification))
        case .unchanged: break
        }

        guard let reference = next.sankalpaReference else {
            return VoiceReduction(state: .clarifying(next, question: .sankalpaTitle))
        }
        let pool = context.candidates.isEmpty ? practice.sankalpas : context.candidates
        switch resolver.resolve(reference, among: pool) {
        case .none:
            let message = !practice.latestRefreshReachedService && !practice.hasLoadedPractice
                ? "This Sankalpa cannot be verified while the service is unavailable."
                : "I could not find a Sankalpa matching \"\(reference)\"."
            return VoiceReduction(state: .result(.notSaved(message), savedDraft: context.draft))
        case .ambiguous(let candidates):
            next.candidates = candidates
            next.sankalpaReference = nil
            return VoiceReduction(state: .clarifying(next, question: .chooseSankalpa(candidates)))
        case .one(let match):
            guard let moment = next.sessionMoment else {
                return VoiceReduction(state: .clarifying(next, question: .sessionDateAndTime))
            }
            return VoiceReduction(
                state: .reviewingSession(
                    VoiceSessionProposal(
                        sankalpaID: match.id,
                        title: match.title,
                        occurredAt: moment
                    )
                )
            )
        }
    }

    private enum MomentUpdate {
        case value(CalendarMoment)
        case clarify(Clarification)
        case unchanged
    }

    private func sessionMoment(
        turn: InterpretedTurn,
        existingDay: CalendarDay?,
        existing: CalendarMoment?,
        now: CalendarMoment
    ) -> MomentUpdate {
        let hasDate = turn.year != nil || turn.month != nil || turn.day != nil || turn.datePhrase != nil
        let hasTime = turn.hour != nil || turn.minute != nil || turn.timePhrase != nil
        guard hasDate || hasTime else {
            if let existing { return .value(existing) }
            return .unchanged
        }

        let isToday = turn.datePhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("today") == .orderedSame
        let todayOnly = isToday && turn.hour == nil
        if todayOnly && turn.timePhrase == nil { return .value(now) }

        let day: CalendarDay
        if let year = turn.year, let month = turn.month, let dayValue = turn.day,
           let parsed = CalendarDay(year: year, month: month, day: dayValue) {
            day = parsed
        } else if isToday {
            day = now.day
        } else if turn.datePhrase == nil, let knownDay = existingDay ?? existing?.day {
            day = knownDay
        } else {
            return .clarify(.sessionDateAndTime)
        }

        guard let hour = turn.hour, (0...23).contains(hour),
              let minute = turn.minute, (0...59).contains(minute)
        else { return .clarify(.exactSessionTime) }
        return .value(CalendarMoment(day: day, hour: hour, minute: minute))
    }

    private func reduceDeclaration(
        draft: VoiceDeclarationDraft,
        turn: InterpretedTurn,
        now: CalendarMoment
    ) -> VoiceReduction {
        if turn.intent == .confirm, let proposal = proposal(from: draft, now: now) {
            return VoiceReduction(state: .executing(proposal.id), effect: .declare(proposal))
        }
        guard turn.intent == .updateDeclaration else {
            return VoiceReduction(
                state: proposal(from: draft, now: now).map(VoiceConversationState.reviewingDeclaration)
                    ?? .editingDeclaration(draft, nextQuestion: nextQuestion(for: draft))
            )
        }

        let patched = apply(turn, to: draft)
        if let question = nextQuestion(for: patched) {
            return VoiceReduction(
                state: .editingDeclaration(patched, nextQuestion: question),
                effect: patched == draft ? nil : .saveDraft(patched)
            )
        }
        guard let proposal = proposal(from: patched, now: now) else {
            let message = declarationError(for: patched, now: now) ?? "Review the declaration values."
            return VoiceReduction(
                state: .editingDeclaration(patched, nextQuestion: .invalidValue(message)),
                effect: patched == draft ? nil : .saveDraft(patched)
            )
        }
        return VoiceReduction(
            state: .reviewingDeclaration(proposal),
            effect: patched == draft ? nil : .saveDraft(patched)
        )
    }

    private func apply(
        _ turn: InterpretedTurn,
        to draft: VoiceDeclarationDraft
    ) -> VoiceDeclarationDraft {
        var result = draft
        for field in turn.changedDraftFields {
            switch field {
            case .title:
                if let value = turn.title { result.title = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            case .description:
                if turn.clearDescription { result.descriptionText = nil }
                else if let value = turn.descriptionText { result.descriptionText = value }
            case .actionType:
                if let value = turn.actionType { result.actionType = value }
            case .startDate:
                if let year = turn.startYear, let month = turn.startMonth, let day = turn.startDay,
                   let value = CalendarDay(year: year, month: month, day: day) {
                    result.startDate = value
                }
            case .periodUnit:
                if let value = turn.periodUnit { result.periodUnit = value }
            case .timesPerPeriod:
                if let value = turn.timesPerPeriod { result.timesPerPeriod = value }
            case .duration:
                if turn.clearDuration { result.duration = nil }
                else if let count = turn.durationCount, let unit = turn.durationUnit {
                    result.duration = VoiceDuration(count: count, unit: unit)
                }
            }
        }
        if result != draft { result.revision += 1 }
        return result
    }

    private func nextQuestion(for draft: VoiceDeclarationDraft) -> Clarification? {
        if draft.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .draftTitle
        }
        if draft.actionType == nil { return .actionType }
        if draft.startDate == nil { return .startDate }
        if draft.periodUnit == nil { return .periodUnit }
        if draft.timesPerPeriod == nil { return .timesPerPeriod }
        if let duration = draft.duration, let period = draft.periodUnit, duration.unit != period {
            return .durationInPeriod(period)
        }
        return nil
    }

    private func proposal(
        from draft: VoiceDeclarationDraft,
        now: CalendarMoment
    ) -> VoiceDeclarationProposal? {
        guard let declaration = draft.declaration,
              let sankalpa = try? Sankalpa.declare(declaration, now: now)
        else { return nil }
        return VoiceDeclarationProposal(
            draft: draft,
            declaration: declaration,
            endDate: sankalpa.endDate
        )
    }

    private func declarationError(
        for draft: VoiceDeclarationDraft,
        now: CalendarMoment
    ) -> String? {
        guard let declaration = draft.declaration else { return nil }
        do {
            _ = try Sankalpa.declare(declaration, now: now)
            return nil
        } catch {
            return error.message
        }
    }
}
