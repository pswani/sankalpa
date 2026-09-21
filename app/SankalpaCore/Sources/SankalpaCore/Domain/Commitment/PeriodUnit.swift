import Foundation

/// The requirement's Period: Day, Week, Month, or Year.
public enum PeriodUnit: String, CaseIterable, Codable, Sendable {
    case day
    case week
    case month
    case year

    public var displayName: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }

    /// "twice a day", "4 times a week"
    public var perPhrase: String {
        switch self {
        case .day: return "a day"
        case .week: return "a week"
        case .month: return "a month"
        case .year: return "a year"
        }
    }

    /// "today", "this week" — reads naturally in "1 of 2 today".
    public var currentPeriodPhrase: String {
        switch self {
        case .day: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .year: return "this year"
        }
    }

    /// The same phrase as a heading.
    public var currentPeriodTitle: String { currentPeriodPhrase.capitalized }

    public func pluralName(_ count: Int) -> String {
        count == 1 ? displayName.lowercased() : "\(displayName.lowercased())s"
    }

    /// The most days one period of this unit can span. Used to bound a caller-supplied date
    /// range before any windows are built, so "at most n periods" costs at most n periods.
    var maxDayCount: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 31
        case .year: return 366
        }
    }

    /// The start of the window `index` periods after `start`.
    ///
    /// Every boundary is derived from the original start date plus the period index, never by
    /// advancing the previous (possibly clamped) boundary. That is what keeps a January 31 monthly
    /// commitment on the 31st after passing through February (DD-12).
    public func boundary(from start: CalendarDay, index: Int) -> CalendarDay {
        switch self {
        case .day: return start.addingDays(index)
        case .week: return start.addingDays(index * 7)
        case .month: return start.addingMonths(index)
        case .year: return start.addingYears(index)
        }
    }

    /// A lower bound on how many periods have started between two dates. The caller corrects it,
    /// so month/year clamping never has to be exact here.
    func estimatedIndex(from start: CalendarDay, to date: CalendarDay) -> Int {
        switch self {
        case .day: return start.days(until: date)
        case .week: return Int((Double(start.days(until: date)) / 7.0).rounded(.down))
        case .month: return start.months(until: date)
        case .year: return Int((Double(start.months(until: date)) / 12.0).rounded(.down))
        }
    }
}
