import Foundation
import FoundationModels
import SankalpaCore

@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelVoiceInterpreter: VoiceInterpreting {
    private let instructions: String

    public init() throws {
        guard let url = Bundle.module.url(
            forResource: "voice-interpreter-v1", withExtension: "txt"
        ) else { throw VoiceInterpretationError.unavailable }
        self.instructions = try String(contentsOf: url, encoding: .utf8)
    }

    public func interpret(
        _ utterance: String,
        context: VoiceInterpretationContext
    ) async throws -> InterpretedTurn {
        guard case .available = SystemLanguageModel.default.availability else {
            throw VoiceInterpretationError.unavailable
        }
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt(for: utterance, context: context),
            generating: GeneratedVoiceTurn.self
        )
        return try response.content.interpreted
    }

    private func prompt(
        for utterance: String,
        context: VoiceInterpretationContext
    ) -> String {
        var lines = [
            "Current local date and time: \(context.nowDescription)",
            "Conversation phase: \(context.phase.rawValue)",
            "User utterance: \(utterance)"
        ]
        if let draft = context.draft {
            lines.append("Current draft: \(Self.describe(draft))")
        }
        if let clarification = context.clarification {
            lines.append("The app just asked: \(clarification.question)")
        }
        if !context.candidateTitles.isEmpty {
            lines.append("Allowed title candidates: \(context.candidateTitles.joined(separator: " | "))")
        }
        if let title = context.sessionProposalTitle,
           let moment = context.sessionProposalMoment {
            lines.append("Current session proposal: title=\(title), occurredAt=\(moment)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ draft: VoiceDeclarationDraft) -> String {
        [
            draft.title.map { "title=\($0)" },
            draft.descriptionText.map { "description=\($0)" },
            draft.actionType.map { "actionType=\($0.rawValue)" },
            draft.startDate.map { "start=\($0.year)-\($0.month)-\($0.day)" },
            draft.periodUnit.map { "period=\($0.rawValue)" },
            draft.timesPerPeriod.map { "times=\($0)" },
            draft.duration.map { "duration=\($0.count) \($0.unit.rawValue)" }
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct GeneratedVoiceTurn: Sendable {
    var intent: GeneratedVoiceIntent
    var sankalpaReference: String?
    var datePhrase: String?
    var timePhrase: String?
    var year: Int?
    var month: Int?
    var day: Int?
    var hour: Int?
    var minute: Int?
    var changedDraftFields: [GeneratedDraftField]
    var title: String?
    var descriptionText: String?
    var clearDescription: Bool
    var actionType: GeneratedActionType?
    var startYear: Int?
    var startMonth: Int?
    var startDay: Int?
    var periodUnit: GeneratedPeriodUnit?
    var timesPerPeriod: Int?
    var durationCount: Int?
    var durationUnit: GeneratedPeriodUnit?
    var clearDuration: Bool

    var interpreted: InterpretedTurn {
        get throws {
            guard (month.map { 1...12 ~= $0 } ?? true),
                  (day.map { 1...31 ~= $0 } ?? true),
                  (hour.map { 0...23 ~= $0 } ?? true),
                  (minute.map { 0...59 ~= $0 } ?? true)
            else { throw VoiceInterpretationError.invalidResponse("Invalid calendar values") }

            return InterpretedTurn(
                intent: intent.value,
                sankalpaReference: sankalpaReference,
                datePhrase: datePhrase,
                timePhrase: timePhrase,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                changedDraftFields: Set(changedDraftFields.map(\.value)),
                title: title,
                descriptionText: descriptionText,
                clearDescription: clearDescription,
                actionType: actionType?.value,
                startYear: startYear,
                startMonth: startMonth,
                startDay: startDay,
                periodUnit: periodUnit?.value,
                timesPerPeriod: timesPerPeriod,
                durationCount: durationCount,
                durationUnit: durationUnit?.value,
                clearDuration: clearDuration
            )
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private enum GeneratedVoiceIntent: String, Sendable {
    case logSession, updateDeclaration, confirm, cancel, resumeDraft, discardDraft, unsupported
    var value: VoiceIntent { VoiceIntent(rawValue: rawValue) ?? .unsupported }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private enum GeneratedDraftField: String, Sendable {
    case title, description, actionType, startDate, periodUnit, timesPerPeriod, duration
    var value: DraftField { DraftField(rawValue: rawValue) ?? .title }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private enum GeneratedActionType: String, Sendable {
    case meditation, pranayama, physicalActivity, observance
    var value: ActionType { ActionType(rawValue: rawValue) ?? .observance }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private enum GeneratedPeriodUnit: String, Sendable {
    case day, week, month, year
    var value: PeriodUnit { PeriodUnit(rawValue: rawValue) ?? .day }
}
