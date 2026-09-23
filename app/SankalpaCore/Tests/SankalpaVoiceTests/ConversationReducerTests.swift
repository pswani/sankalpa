import Foundation
import Testing
@testable import SankalpaVoice
@testable import SankalpaCore

@Suite("Voice conversation reducer")
struct ConversationReducerTests {
    let reducer = VoiceConversationReducer()
    let now = CalendarMoment(
        day: CalendarDay(year: 2026, month: 9, day: 22)!, hour: 14, minute: 35
    )
    let vipassana = VoiceSankalpaReference(id: SankalpaId(), title: "Vipassana")

    var practice: VoicePracticeSnapshot {
        VoicePracticeSnapshot(
            sankalpas: [vipassana], hasLoadedPractice: true, latestRefreshReachedService: true
        )
    }

    @Test("Today without a time proposes the exact current moment")
    func todayMeansNow() {
        let turn = InterpretedTurn(
            intent: .logSession, sankalpaReference: "vipassana", datePhrase: "today"
        )
        let result = reducer.reduce(.idle(savedDraft: nil), turn: turn, practice: practice, now: now)
        guard case .reviewingSession(let proposal) = result.state else {
            Issue.record("Expected a session proposal")
            return
        }
        #expect(proposal.occurredAt == now)
        #expect(result.effect == nil)
    }

    @Test("Today with an exact time uses today's date")
    func todayWithExactTime() {
        let turn = InterpretedTurn(
            intent: .logSession,
            sankalpaReference: "vipassana",
            datePhrase: "today",
            timePhrase: "8:15 this morning",
            hour: 8,
            minute: 15
        )
        let result = reducer.reduce(.idle(savedDraft: nil), turn: turn, practice: practice, now: now)
        guard case .reviewingSession(let proposal) = result.state else {
            Issue.record("Expected a session proposal")
            return
        }
        #expect(proposal.occurredAt.day == now.day)
        #expect(proposal.occurredAt.hour == 8)
        #expect(proposal.occurredAt.minute == 15)
    }

    @Test("A different date without an exact time asks instead of inventing one")
    func dateNeedsExactTime() {
        let turn = InterpretedTurn(
            intent: .logSession,
            sankalpaReference: "vipassana",
            datePhrase: "yesterday",
            year: 2026,
            month: 9,
            day: 21
        )
        let result = reducer.reduce(.idle(savedDraft: nil), turn: turn, practice: practice, now: now)
        guard case .clarifying(_, let question) = result.state else {
            Issue.record("Expected clarification")
            return
        }
        #expect(question == .exactSessionTime)
    }

    @Test("A clarified date is preserved while asking for its exact time")
    func clarifiedDateIsPreserved() {
        let first = InterpretedTurn(
            intent: .logSession,
            sankalpaReference: "vipassana",
            datePhrase: "yesterday",
            year: 2026,
            month: 9,
            day: 21
        )
        let firstResult = reducer.reduce(
            .idle(savedDraft: nil), turn: first, practice: practice, now: now
        )
        guard case .clarifying(let context, .exactSessionTime) = firstResult.state else {
            Issue.record("Expected an exact-time clarification")
            return
        }

        let answer = InterpretedTurn(intent: .logSession, hour: 8, minute: 15)
        let secondResult = reducer.reduce(
            .clarifying(context, question: .exactSessionTime),
            turn: answer,
            practice: practice,
            now: now
        )
        guard case .reviewingSession(let proposal) = secondResult.state else {
            Issue.record("Expected a session proposal")
            return
        }
        #expect(proposal.occurredAt.day == CalendarDay(year: 2026, month: 9, day: 21))
        #expect(proposal.occurredAt.hour == 8)
        #expect(proposal.occurredAt.minute == 15)
    }

    @Test("A proposal never executes before explicit confirmation")
    func proposalNeedsConfirmation() {
        let proposal = VoiceSessionProposal(
            sankalpaID: vipassana.id, title: vipassana.title, occurredAt: now
        )
        let unrelated = reducer.reduce(
            .reviewingSession(proposal),
            turn: InterpretedTurn(intent: .unsupported),
            practice: practice,
            now: now
        )
        #expect(unrelated.effect == nil)

        let confirmation = reducer.reduce(
            .reviewingSession(proposal),
            turn: InterpretedTurn(intent: .confirm),
            practice: practice,
            now: now
        )
        #expect(confirmation.effect == .logSession(proposal))
        #expect(confirmation.state == .executing(proposal.id))
    }

    @Test("A repeated confirmation cannot execute twice")
    func repeatedConfirmationIsIgnored() {
        let proposal = VoiceSessionProposal(
            sankalpaID: vipassana.id, title: vipassana.title, occurredAt: now
        )
        let result = reducer.reduce(
            .executing(proposal.id),
            turn: InterpretedTurn(intent: .confirm),
            practice: practice,
            now: now
        )
        #expect(result.effect == nil)
        #expect(result.state == .executing(proposal.id))
    }

    @Test("Only explicitly changed draft fields are patched")
    func patchChangesNamedFieldsOnly() {
        let original = VoiceDeclarationDraft(
            title: "Morning sit",
            descriptionText: "Quietly",
            actionType: .meditation,
            startDate: now.day,
            periodUnit: .day,
            timesPerPeriod: 1
        )
        let turn = InterpretedTurn(
            intent: .updateDeclaration,
            changedDraftFields: [.title],
            title: "Evening sit",
            descriptionText: "This generated value must be ignored",
            clearDescription: true,
            actionType: .physicalActivity
        )
        let result = reducer.reduce(
            .editingDeclaration(original, nextQuestion: nil),
            turn: turn,
            practice: practice,
            now: now
        )
        let draft = result.state.savedDraft
        #expect(draft?.title == "Evening sit")
        #expect(draft?.descriptionText == "Quietly")
        #expect(draft?.actionType == .meditation)
        #expect(draft?.revision == original.revision + 1)
    }

    @Test("Optional fields clear only with an explicit clear flag")
    func explicitClear() {
        let original = VoiceDeclarationDraft(
            title: "Sit",
            descriptionText: "Quietly",
            actionType: .meditation,
            startDate: now.day,
            periodUnit: .day,
            timesPerPeriod: 1,
            duration: VoiceDuration(count: 30, unit: .day)
        )
        let turn = InterpretedTurn(
            intent: .updateDeclaration,
            changedDraftFields: [.description, .duration],
            clearDescription: true,
            clearDuration: true
        )
        let result = reducer.reduce(
            .editingDeclaration(original, nextQuestion: nil), turn: turn, practice: practice, now: now
        )
        #expect(result.state.savedDraft?.descriptionText == nil)
        #expect(result.state.savedDraft?.duration == nil)
    }

    @Test("Missing declaration fields are requested in a stable order")
    func requiredFieldOrder() {
        var state: VoiceConversationState = .idle(savedDraft: nil)
        let title = InterpretedTurn(
            intent: .updateDeclaration, changedDraftFields: [.title], title: "Walk"
        )
        state = reducer.reduce(state, turn: title, practice: practice, now: now).state
        guard case .editingDeclaration(_, let question) = state else {
            Issue.record("Expected an editing state")
            return
        }
        #expect(question == .actionType)
    }

    @Test("A duration in another unit is never converted silently")
    func durationUnitMismatch() {
        let draft = VoiceDeclarationDraft(
            title: "Walk",
            actionType: .physicalActivity,
            startDate: now.day,
            periodUnit: .week,
            timesPerPeriod: 4,
            duration: VoiceDuration(count: 30, unit: .day)
        )
        let result = reducer.reduce(
            .editingDeclaration(draft, nextQuestion: nil),
            turn: InterpretedTurn(intent: .updateDeclaration),
            practice: practice,
            now: now
        )
        guard case .editingDeclaration(_, let question) = result.state else {
            Issue.record("Expected clarification")
            return
        }
        #expect(question == .durationInPeriod(.week))
        #expect(result.effect == nil)
    }

    @Test("Revising a reviewed declaration creates a new proposal id")
    func revisionInvalidatesProposal() throws {
        let draft = VoiceDeclarationDraft(
            title: "Walk", actionType: .physicalActivity, startDate: now.day,
            periodUnit: .day, timesPerPeriod: 1
        )
        let declaration = try #require(draft.declaration)
        let old = VoiceDeclarationProposal(
            draft: draft, declaration: declaration, endDate: nil
        )
        let turn = InterpretedTurn(
            intent: .updateDeclaration, changedDraftFields: [.timesPerPeriod], timesPerPeriod: 2
        )
        let result = reducer.reduce(
            .reviewingDeclaration(old), turn: turn, practice: practice, now: now
        )
        guard case .reviewingDeclaration(let revised) = result.state else {
            Issue.record("Expected revised proposal")
            return
        }
        #expect(revised.id != old.id)
        #expect(revised.declaration.timesPerPeriod == 2)
    }

    @Test("Offline without cached practice refuses an unverifiable title")
    func noCacheOffline() {
        let offline = VoicePracticeSnapshot(
            sankalpas: [], hasLoadedPractice: false, latestRefreshReachedService: false
        )
        let turn = InterpretedTurn(
            intent: .logSession, sankalpaReference: "Vipassana", datePhrase: "today"
        )
        let result = reducer.reduce(.idle(savedDraft: nil), turn: turn, practice: offline, now: now)
        #expect(result.state == .result(
            .notSaved("This Sankalpa cannot be verified while the service is unavailable."),
            savedDraft: nil
        ))
    }

    @Test("Cancel retains a declaration draft")
    func cancelRetainsDraft() {
        let draft = VoiceDeclarationDraft(title: "Walk")
        let result = reducer.reduce(
            .editingDeclaration(draft, nextQuestion: .actionType),
            turn: InterpretedTurn(intent: .cancel),
            practice: practice,
            now: now
        )
        #expect(result.state == .idle(savedDraft: draft))
    }

    @Test("Resuming a complete saved draft immediately shows a fresh proposal")
    func resumeCompleteDraft() {
        let draft = VoiceDeclarationDraft(
            title: "Walk", actionType: .physicalActivity, startDate: now.day,
            periodUnit: .day, timesPerPeriod: 1
        )
        let result = reducer.reduce(
            .choosingSavedDraft(draft),
            turn: InterpretedTurn(intent: .resumeDraft),
            practice: practice,
            now: now
        )
        guard case .reviewingDeclaration(let proposal) = result.state else {
            Issue.record("Expected a declaration proposal")
            return
        }
        #expect(proposal.draft == draft)
        #expect(result.effect == nil)
    }
}
