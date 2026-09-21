import Foundation

/// A date and a time of day, with no time zone attached — the domain's equivalent of a local
/// date-time. Sessions occur at a moment; lifecycle transitions take effect at a moment.
public struct CalendarMoment: Hashable, Comparable, Codable, Sendable {
    public static let secondsPerDay = 86_400

    public let day: CalendarDay
    /// Seconds since midnight, in `0..<86_400`.
    public let secondOfDay: Int

    public init(day: CalendarDay, secondOfDay: Int) {
        self.day = day
        self.secondOfDay = min(max(secondOfDay, 0), CalendarMoment.secondsPerDay - 1)
    }

    public init(day: CalendarDay, hour: Int, minute: Int = 0, second: Int = 0) {
        self.init(day: day, secondOfDay: hour * 3600 + minute * 60 + second)
    }

    /// The first moment of a day — the lower bound of a period window.
    public static func startOfDay(_ day: CalendarDay) -> CalendarMoment {
        CalendarMoment(day: day, secondOfDay: 0)
    }

    /// The last moment of a day — the upper bound of an inclusive period window.
    public static func endOfDay(_ day: CalendarDay) -> CalendarMoment {
        CalendarMoment(day: day, secondOfDay: secondsPerDay - 1)
    }

    public var hour: Int { secondOfDay / 3600 }
    public var minute: Int { (secondOfDay % 3600) / 60 }

    public static func < (lhs: CalendarMoment, rhs: CalendarMoment) -> Bool {
        (lhs.day, lhs.secondOfDay) < (rhs.day, rhs.secondOfDay)
    }
}
