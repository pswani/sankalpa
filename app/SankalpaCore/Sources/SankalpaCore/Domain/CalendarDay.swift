import Foundation

/// A date on the proleptic Gregorian calendar, with no time zone attached.
///
/// The requirements talk about dates ("start date", "end date", "period boundary") independently of
/// any clock or zone. Modelling that directly — rather than reusing `Foundation.Date` — keeps every
/// period boundary a pure function of year/month/day, so daylight-saving shifts and zone changes
/// can never move a boundary. Conversion between an instant and a `CalendarDay` happens once, in
/// the clock adapter, using the single configured application time zone (see 09-open-questions Q1).
public struct CalendarDay: Hashable, Comparable, Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month) else { return nil }
        guard (1...CalendarDay.lastDay(ofMonth: month, year: year)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Builds a date, clamping the day to the last valid day of the target month.
    ///
    /// This is the rule the requirements state for period boundaries: "When the corresponding day
    /// does not exist in a month or year, the boundary uses the last valid day."
    public init(year: Int, month: Int, clampedDay day: Int) {
        let normalisedMonthIndex = year * 12 + (month - 1)
        let y = Int((Double(normalisedMonthIndex) / 12.0).rounded(.down))
        let m = normalisedMonthIndex - y * 12 + 1
        self.year = y
        self.month = m
        self.day = min(max(day, 1), CalendarDay.lastDay(ofMonth: m, year: y))
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: - Arithmetic

    public func addingDays(_ count: Int) -> CalendarDay {
        CalendarDay(serialNumber: serialNumber + count)
    }

    /// Adds whole months, keeping the day of month and clamping to the last valid day.
    public func addingMonths(_ count: Int) -> CalendarDay {
        CalendarDay(year: year, month: month + count, clampedDay: day)
    }

    /// Adds whole years, keeping month and day and clamping (February 29 in a common year).
    public func addingYears(_ count: Int) -> CalendarDay {
        CalendarDay(year: year + count, month: month, clampedDay: day)
    }

    public func days(until other: CalendarDay) -> Int {
        other.serialNumber - serialNumber
    }

    /// Whole months from this day to `other`, counting only months that have fully elapsed.
    public func months(until other: CalendarDay) -> Int {
        let raw = (other.year * 12 + other.month) - (year * 12 + month)
        return other.day < min(day, CalendarDay.lastDay(ofMonth: other.month, year: other.year))
            ? raw - 1
            : raw
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func lastDay(ofMonth month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeapYear(year) ? 29 : 28
        }
    }

    // MARK: - Serial number conversion

    /// Days since 1970-01-01, using Howard Hinnant's `days_from_civil`. Integer-only, so the same
    /// input always yields the same boundary on every device and in every locale.
    public var serialNumber: Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    public init(serialNumber: Int) {
        let z = serialNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let y = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        self.day = dayOfYear - (153 * mp + 2) / 5 + 1
        self.month = mp + (mp < 10 ? 3 : -9)
        self.year = y + (self.month <= 2 ? 1 : 0)
    }
}
