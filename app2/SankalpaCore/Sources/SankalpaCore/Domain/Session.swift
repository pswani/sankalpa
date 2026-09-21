import Foundation

/// A recorded past fact: the user performed the intended action on one occasion. It has no
/// behaviour beyond being valid at construction, and it is created only by `Sankalpa.logSession`
/// so the commitment and lifecycle rules stay with the object that owns them (DD-5).
public struct Session: Hashable, Codable, Sendable, Identifiable {
    public let id: SessionId
    public let sankalpaId: SankalpaId
    public let occurredAt: CalendarMoment
    public let loggedAt: CalendarMoment

    init(
        id: SessionId,
        sankalpaId: SankalpaId,
        occurredAt: CalendarMoment,
        loggedAt: CalendarMoment
    ) {
        self.id = id
        self.sankalpaId = sankalpaId
        self.occurredAt = occurredAt
        self.loggedAt = loggedAt
    }

    /// Rehydration from storage, which must not re-run rules that were already checked when the
    /// session was first accepted.
    public static func rehydrate(
        id: SessionId,
        sankalpaId: SankalpaId,
        occurredAt: CalendarMoment,
        loggedAt: CalendarMoment
    ) -> Session {
        Session(id: id, sankalpaId: sankalpaId, occurredAt: occurredAt, loggedAt: loggedAt)
    }

    public var wasBackdated: Bool { occurredAt.day != loggedAt.day }
}
