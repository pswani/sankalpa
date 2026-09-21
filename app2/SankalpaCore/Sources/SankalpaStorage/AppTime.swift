import Foundation
import SankalpaCore

/// A stable timezone per running session. Wall dates retain their meaning after travel.
/// Reopening uses the device zone; historical wall dates are never rebucketed.
public enum AppTime {
    public static let timeZone = TimeZone.current
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
    public static func moment(from date: Date) -> CalendarMoment {
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return CalendarMoment(day: CalendarDay(year: p.year!, month: p.month!, day: p.day!)!, hour: p.hour!, minute: p.minute!, second: p.second!)
    }
    public static func day(from date: Date) -> CalendarDay { moment(from: date).day }
    public static func date(from moment: CalendarMoment) -> Date {
        calendar.date(from: DateComponents(year: moment.day.year, month: moment.day.month, day: moment.day.day, hour: moment.hour, minute: moment.minute, second: moment.secondOfDay % 60))!
    }
    public static func date(from day: CalendarDay) -> Date { date(from: .startOfDay(day)) }
    public static func timeText(_ moment: CalendarMoment) -> String {
        date(from: moment).formatted(date: .omitted, time: .shortened)
    }
    public static func dayText(_ day: CalendarDay, today: CalendarDay) -> String {
        if day == today { return "Today" }
        if day == today.addingDays(-1) { return "Yesterday" }
        return date(from: day).formatted(date: .abbreviated, time: .omitted)
    }
}
public struct SystemClock: SankalpaClock {
    public init() {}
    public func now() -> CalendarMoment { AppTime.moment(from: Date()) }
}
