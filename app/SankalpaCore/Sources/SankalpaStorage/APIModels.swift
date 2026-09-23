import Foundation
import SankalpaCore

/// The wire shapes of the Sankalpa REST API, decoded exactly as the service publishes them.
///
/// These are deliberately dumb mirrors of the OpenAPI schemas — strings where the service sends
/// strings — so that a contract change surfaces here as a decode failure rather than somewhere
/// deep in the domain. `APIMapping` turns them into domain values.
enum API {

    // MARK: - Requests

    struct DeclareRequest: Encodable, Sendable {
        let id: UUID
        let title: String
        let description: String
        let actionType: String
        let startDate: String
        let periodUnit: String
        let timesPerPeriod: Int
        let periodCount: Int?
    }

    struct BeginRequest: Encodable, Sendable {
        let effectiveAt: String?
    }

    struct CompleteRequest: Encodable, Sendable {
        let outcome: String
    }

    struct LogSessionRequest: Encodable, Sendable {
        let id: UUID
        let occurredAt: String
    }

    // MARK: - Responses

    struct SankalpaResponse: Decodable, Sendable {
        let id: UUID
        let title: String
        let description: String
        let actionType: String
        let startDate: String
        let endDate: String?
        let periodUnit: String
        let timesPerPeriod: Int
        let periodCount: Int?
        let lifecycleState: String
        let declaredAt: String
    }

    struct SessionResponse: Decodable, Sendable {
        let id: UUID
        let sankalpaId: UUID
        let occurredAt: String
        let loggedAt: String
    }

    struct SessionPageResponse: Decodable, Sendable {
        let content: [SessionResponse]
        let page: Int
        let size: Int
        let totalElements: Int
        let totalPages: Int
    }

    struct LifecycleTransitionResponse: Decodable, Sendable {
        let from: String
        let to: String
        let effectiveAt: String
        let recordedAt: String
    }

    /// RFC 9457 problem details. `code` is the stable application code the service documents; the
    /// rest is for diagnostics.
    struct Problem: Decodable, Sendable {
        let status: Int?
        let detail: String?
        let code: String?
        let errors: [String: String]?
    }
}

// MARK: - Enum translation

/// The service spells enums in `UPPER_SNAKE_CASE`; the domain spells them in `camelCase`. The two
/// are listed explicitly rather than derived, so adding a case to either side fails to compile
/// instead of silently falling through to a default.
enum APIEnum {

    static func actionType(_ wire: String) -> ActionType? {
        switch wire {
        case "MEDITATION": return .meditation
        case "PRANAYAMA": return .pranayama
        case "PHYSICAL_ACTIVITY": return .physicalActivity
        case "OBSERVANCE": return .observance
        default: return nil
        }
    }

    static func wire(_ value: ActionType) -> String {
        switch value {
        case .meditation: return "MEDITATION"
        case .pranayama: return "PRANAYAMA"
        case .physicalActivity: return "PHYSICAL_ACTIVITY"
        case .observance: return "OBSERVANCE"
        }
    }

    static func periodUnit(_ wire: String) -> PeriodUnit? {
        switch wire {
        case "DAY": return .day
        case "WEEK": return .week
        case "MONTH": return .month
        case "YEAR": return .year
        default: return nil
        }
    }

    static func wire(_ value: PeriodUnit) -> String {
        switch value {
        case .day: return "DAY"
        case .week: return "WEEK"
        case .month: return "MONTH"
        case .year: return "YEAR"
        }
    }

    static func lifecycleState(_ wire: String) -> LifecycleState? {
        switch wire {
        case "NOT_STARTED": return .notStarted
        case "IN_PROGRESS": return .inProgress
        case "PAUSED": return .paused
        case "COMPLETED_SUCCESSFULLY": return .completedSuccessfully
        case "COMPLETED_UNSUCCESSFULLY": return .completedUnsuccessfully
        case "STOPPED": return .stopped
        default: return nil
        }
    }

    static func wire(_ value: CompletionOutcome) -> String {
        switch value {
        case .successfully: return "SUCCESSFUL"
        case .unsuccessfully: return "UNSUCCESSFUL"
        }
    }
}
