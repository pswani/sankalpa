import Foundation

/// One audit entry. `effectiveAt` drives domain behaviour; `recordedAt` preserves when the user
/// actually performed it. S14 — only Begin may have the two differ.
public struct LifecycleTransition: Hashable, Codable, Sendable {
    public let from: LifecycleState
    public let to: LifecycleState
    public let effectiveAt: CalendarMoment
    public let recordedAt: CalendarMoment

    public init(
        from: LifecycleState,
        to: LifecycleState,
        effectiveAt: CalendarMoment,
        recordedAt: CalendarMoment
    ) {
        self.from = from
        self.to = to
        self.effectiveAt = effectiveAt
        self.recordedAt = recordedAt
    }

    public var wasBackdated: Bool { effectiveAt != recordedAt }
}

/// Effective and recorded timestamps for the one transition that may be backdated.
public struct BeginTiming: Hashable, Sendable {
    public let effectiveAt: CalendarMoment
    public let recordedAt: CalendarMoment

    public init(effectiveAt: CalendarMoment, recordedAt: CalendarMoment) {
        self.effectiveAt = effectiveAt
        self.recordedAt = recordedAt
    }

    /// Begin, taking effect now.
    public init(now: CalendarMoment) {
        self.init(effectiveAt: now, recordedAt: now)
    }
}
