import Foundation

public enum PeriodStanding: String, Codable, Sendable {
    /// The window has not closed yet, so it is neither satisfied nor missed.
    case open
    /// S13 — the sankalpa was Paused for this window's entire span.
    case paused
    case satisfied
    case unsatisfied

    public var displayName: String {
        switch self {
        case .open: return "Open"
        case .paused: return "Paused"
        case .satisfied: return "Satisfied"
        case .unsatisfied: return "Missed"
        }
    }
}

/// A derived result for one period. Never stored — a stored copy would be a second truth that can
/// drift from the commitment, the lifecycle and the sessions it comes from (DD-6).
public struct PeriodOutcome: Hashable, Codable, Sendable, Identifiable {
    public let window: PeriodWindow
    public let required: Int
    public let performed: Int
    /// S12 — the derived shortfall, never negative, and always zero for open or paused windows.
    public let missed: Int
    public let standing: PeriodStanding

    public var id: Int { window.index }

    public init(
        window: PeriodWindow,
        required: Int,
        performed: Int,
        missed: Int,
        standing: PeriodStanding
    ) {
        self.window = window
        self.required = required
        self.performed = performed
        self.missed = missed
        self.standing = standing
    }

    /// Progress toward the minimum, clamped at 1 because performing more than committed still just
    /// satisfies the period.
    public var completionFraction: Double {
        guard required > 0 else { return 1 }
        return min(1, Double(performed) / Double(required))
    }

    public var exceededCommitment: Bool { performed > required }
}
