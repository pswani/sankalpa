import Foundation

extension CalendarDay {
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]
    private static let shortMonthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]

    public var longDisplayText: String { "\(CalendarDay.monthNames[month - 1]) \(day), \(year)" }
    public var shortDisplayText: String { "\(day) \(CalendarDay.shortMonthNames[month - 1]) \(year)" }
    public var compactDisplayText: String { "\(day) \(CalendarDay.shortMonthNames[month - 1])" }
}
