import Foundation
import SankalpaCore

struct ExtensionAttempt: Codable, Sendable {
    enum State: String, Codable { case unresolved, acceptedAwaitingCache, resolvedNotice, blockedConflict }
    let schemaVersion: Int
    let serviceInstanceId: UUID
    let sourceId: SankalpaId
    let seriesId: SankalpaId
    let extensionId: SankalpaId
    let totalPeriodCount: Int
    let revision: UUID
    let submittedAt: CalendarMoment
    var state: State = .unresolved
    var acceptedResponse: API.ExtensionResponse?
    var acceptedRevision: String?
    var existingChild = false
    var notice: String?

    init(instance: UUID, source: Sankalpa, totalPeriodCount: Int, submittedAt: CalendarMoment) {
        schemaVersion = 1; serviceInstanceId = instance
        sourceId = source.id; seriesId = source.seriesId; extensionId = SankalpaId()
        self.totalPeriodCount = totalPeriodCount; revision = UUID(); self.submittedAt = submittedAt
    }
    var isUnresolved: Bool { state != .resolvedNotice }
}

public enum ExtensionDisposition: Sendable {
    case accepted(SankalpaId, existingChild: Bool)
    case pending(String)
    case refused(String)
    case blocked(String)
}
