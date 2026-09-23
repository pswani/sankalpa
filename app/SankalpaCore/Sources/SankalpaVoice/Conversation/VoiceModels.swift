import Foundation
import SankalpaCore

public struct ProposalID: Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public struct VoiceDuration: Codable, Equatable, Sendable {
    public var count: Int
    public var unit: PeriodUnit

    public init(count: Int, unit: PeriodUnit) {
        self.count = count
        self.unit = unit
    }
}

/// The only voice state persisted between launches. Transcripts and audio are intentionally absent.
public struct VoiceDeclarationDraft: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var revision: Int
    public var title: String?
    public var descriptionText: String?
    public var actionType: ActionType?
    public var startDate: CalendarDay?
    public var periodUnit: PeriodUnit?
    public var timesPerPeriod: Int?
    public var duration: VoiceDuration?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        revision: Int = 0,
        title: String? = nil,
        descriptionText: String? = nil,
        actionType: ActionType? = nil,
        startDate: CalendarDay? = nil,
        periodUnit: PeriodUnit? = nil,
        timesPerPeriod: Int? = nil,
        duration: VoiceDuration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.title = title
        self.descriptionText = descriptionText
        self.actionType = actionType
        self.startDate = startDate
        self.periodUnit = periodUnit
        self.timesPerPeriod = timesPerPeriod
        self.duration = duration
    }

    public var declaration: Declaration? {
        guard let title, let actionType, let startDate, let periodUnit, let timesPerPeriod else {
            return nil
        }
        guard duration == nil || duration?.unit == periodUnit else { return nil }
        return Declaration(
            title: title,
            description: descriptionText ?? "",
            actionType: actionType,
            startDate: startDate,
            periodUnit: periodUnit,
            timesPerPeriod: timesPerPeriod,
            periodCount: duration?.count
        )
    }
}

public enum VoiceIntent: String, Codable, Sendable {
    case logSession
    case updateDeclaration
    case confirm
    case cancel
    case resumeDraft
    case discardDraft
    case unsupported
}

public enum DraftField: String, CaseIterable, Codable, Hashable, Sendable {
    case title
    case description
    case actionType
    case startDate
    case periodUnit
    case timesPerPeriod
    case duration
}

/// Platform-neutral output from interpretation. The reducer trusts the shape, not the values.
public struct InterpretedTurn: Equatable, Sendable {
    public var intent: VoiceIntent
    public var sankalpaReference: String?
    public var datePhrase: String?
    public var timePhrase: String?
    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    public var changedDraftFields: Set<DraftField>
    public var title: String?
    public var descriptionText: String?
    public var clearDescription: Bool
    public var actionType: ActionType?
    public var startYear: Int?
    public var startMonth: Int?
    public var startDay: Int?
    public var periodUnit: PeriodUnit?
    public var timesPerPeriod: Int?
    public var durationCount: Int?
    public var durationUnit: PeriodUnit?
    public var clearDuration: Bool

    public init(
        intent: VoiceIntent,
        sankalpaReference: String? = nil,
        datePhrase: String? = nil,
        timePhrase: String? = nil,
        year: Int? = nil,
        month: Int? = nil,
        day: Int? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        changedDraftFields: Set<DraftField> = [],
        title: String? = nil,
        descriptionText: String? = nil,
        clearDescription: Bool = false,
        actionType: ActionType? = nil,
        startYear: Int? = nil,
        startMonth: Int? = nil,
        startDay: Int? = nil,
        periodUnit: PeriodUnit? = nil,
        timesPerPeriod: Int? = nil,
        durationCount: Int? = nil,
        durationUnit: PeriodUnit? = nil,
        clearDuration: Bool = false
    ) {
        self.intent = intent
        self.sankalpaReference = sankalpaReference
        self.datePhrase = datePhrase
        self.timePhrase = timePhrase
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.changedDraftFields = changedDraftFields
        self.title = title
        self.descriptionText = descriptionText
        self.clearDescription = clearDescription
        self.actionType = actionType
        self.startYear = startYear
        self.startMonth = startMonth
        self.startDay = startDay
        self.periodUnit = periodUnit
        self.timesPerPeriod = timesPerPeriod
        self.durationCount = durationCount
        self.durationUnit = durationUnit
        self.clearDuration = clearDuration
    }
}

public struct VoiceSankalpaReference: Identifiable, Equatable, Sendable {
    public let id: SankalpaId
    public let title: String

    public init(id: SankalpaId, title: String) {
        self.id = id
        self.title = title
    }
}

public struct VoicePracticeSnapshot: Equatable, Sendable {
    public let sankalpas: [VoiceSankalpaReference]
    public let hasLoadedPractice: Bool
    public let latestRefreshReachedService: Bool

    public init(
        sankalpas: [VoiceSankalpaReference],
        hasLoadedPractice: Bool,
        latestRefreshReachedService: Bool
    ) {
        self.sankalpas = sankalpas
        self.hasLoadedPractice = hasLoadedPractice
        self.latestRefreshReachedService = latestRefreshReachedService
    }
}

public struct VoiceSessionProposal: Equatable, Sendable {
    public let id: ProposalID
    public let sankalpaID: SankalpaId
    public let title: String
    public let occurredAt: CalendarMoment
    public let savedDraft: VoiceDeclarationDraft?

    public init(
        id: ProposalID = ProposalID(),
        sankalpaID: SankalpaId,
        title: String,
        occurredAt: CalendarMoment,
        savedDraft: VoiceDeclarationDraft? = nil
    ) {
        self.id = id
        self.sankalpaID = sankalpaID
        self.title = title
        self.occurredAt = occurredAt
        self.savedDraft = savedDraft
    }
}

public struct VoiceDeclarationProposal: Equatable, Sendable {
    public let id: ProposalID
    public let draft: VoiceDeclarationDraft
    public let declaration: Declaration
    public let endDate: CalendarDay?

    public init(
        id: ProposalID = ProposalID(),
        draft: VoiceDeclarationDraft,
        declaration: Declaration,
        endDate: CalendarDay?
    ) {
        self.id = id
        self.draft = draft
        self.declaration = declaration
        self.endDate = endDate
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.draft == rhs.draft &&
            lhs.declaration.title == rhs.declaration.title &&
            lhs.declaration.description == rhs.declaration.description &&
            lhs.declaration.actionType == rhs.declaration.actionType &&
            lhs.declaration.startDate == rhs.declaration.startDate &&
            lhs.declaration.periodUnit == rhs.declaration.periodUnit &&
            lhs.declaration.timesPerPeriod == rhs.declaration.timesPerPeriod &&
            lhs.declaration.periodCount == rhs.declaration.periodCount &&
            lhs.endDate == rhs.endDate
    }
}

public enum Clarification: Equatable, Sendable {
    case sankalpaTitle
    case chooseSankalpa([VoiceSankalpaReference])
    case sessionDateAndTime
    case exactSessionTime
    case draftTitle
    case actionType
    case startDate
    case periodUnit
    case timesPerPeriod
    case durationInPeriod(PeriodUnit)
    case invalidValue(String)

    public var question: String {
        switch self {
        case .sankalpaTitle: return "Which Sankalpa is this session for?"
        case .chooseSankalpa(let candidates):
            return "Which one: " + candidates.map(\.title).joined(separator: ", ") + "?"
        case .sessionDateAndTime: return "When did you perform the session?"
        case .exactSessionTime: return "What exact time did you perform it?"
        case .draftTitle: return "What would you like to call this Sankalpa?"
        case .actionType: return "What type of action is it?"
        case .startDate: return "When does it start?"
        case .periodUnit: return "Is the commitment per day, week, month, or year?"
        case .timesPerPeriod: return "How many times per period?"
        case .durationInPeriod(let unit):
            return "Choose a duration in whole \(unit.pluralName(2))."
        case .invalidValue(let message): return message
        }
    }
}

public enum VoiceResult: Equatable, Sendable {
    case sessionAccepted
    case sessionPending
    case declarationAccepted
    case declarationAcceptedWithDraftCleanupWarning
    case draftOnly(String)
    case notSaved(String)
    case refused(String)

    public var message: String {
        switch self {
        case .sessionAccepted: return "Session logged."
        case .sessionPending: return "Session saved on this iPhone and waiting to be sent."
        case .declarationAccepted: return "Sankalpa declared."
        case .declarationAcceptedWithDraftCleanupWarning:
            return "Sankalpa declared, but its saved draft could not be removed. You can discard the draft safely."
        case .draftOnly(let message), .notSaved(let message), .refused(let message): return message
        }
    }
}
