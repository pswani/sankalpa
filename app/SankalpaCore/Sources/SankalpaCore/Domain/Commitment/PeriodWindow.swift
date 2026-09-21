import Foundation

/// One concrete occurrence of a period, with inclusive bounds (DD-12).
public struct PeriodWindow: Hashable, Sendable {
    /// Zero-based: window 0 begins on the commitment's start date.
    public let index: Int
    public let unit: PeriodUnit
    public let start: CalendarDay
    public let end: CalendarDay

    public init(index: Int, unit: PeriodUnit, start: CalendarDay, end: CalendarDay) {
        self.index = index
        self.unit = unit
        self.start = start
        self.end = end
    }

    public func contains(_ day: CalendarDay) -> Bool {
        day >= start && day <= end
    }

    public func contains(_ moment: CalendarMoment) -> Bool {
        contains(moment.day)
    }

    /// A window is closed once the day after its end has arrived.
    public func isClosed(asOf today: CalendarDay) -> Bool {
        end < today
    }

    public var firstMoment: CalendarMoment { .startOfDay(start) }
    public var lastMoment: CalendarMoment { .endOfDay(end) }
    public var dayCount: Int { start.days(until: end) + 1 }

    /// Reads naturally in "2 of 4 this week".
    public var unitNoun: String { unit.displayName.lowercased() }

    /// "5 Jan – 11 Jan" for multi-day windows, "5 Jan" for a daily one.
    public var displayText: String {
        dayCount == 1 ? start.shortDisplayText : "\(start.compactDisplayText) – \(end.shortDisplayText)"
    }
}
