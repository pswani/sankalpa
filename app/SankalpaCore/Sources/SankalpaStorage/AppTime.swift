import Foundation
import SankalpaCore

/// The one place instants become dates.
///
/// The domain works in wall-clock terms with no time zone attached, so a period boundary can never
/// be moved by a daylight-saving shift. This is the boundary where the system clock and the UI's
/// `Date` values are interpreted, using a single application time zone (09-open-questions Q1). No
/// per-user or per-sankalpa zone is modelled.
public enum AppTime {
    /// Captured once per launch rather than auto-updating. A day already recorded keeps its
    /// meaning if the device crosses a time zone mid-session; a relaunch picks up the new zone.
    public static let timeZone: TimeZone = .current

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    public static func moment(from date: Date) -> CalendarMoment {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return CalendarMoment(
            day: CalendarDay(
                year: parts.year ?? 1970,
                month: parts.month ?? 1,
                clampedDay: parts.day ?? 1
            ),
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: parts.second ?? 0
        )
    }

    public static func day(from date: Date) -> CalendarDay { moment(from: date).day }

    public static func date(from moment: CalendarMoment) -> Date {
        var parts = DateComponents()
        parts.year = moment.day.year
        parts.month = moment.day.month
        parts.day = moment.day.day
        parts.hour = moment.hour
        parts.minute = moment.minute
        // Seconds are carried through: dropping them rounds a moment backwards, which can push a
        // session just before a Begin or Resume and make it ineligible.
        parts.second = moment.secondOfDay % 60
        return calendar.date(from: parts) ?? Date()
    }

    public static func date(from day: CalendarDay) -> Date {
        date(from: CalendarMoment.startOfDay(day))
    }

    /// "Today", "Yesterday", or the date — for journal and session-list headers.
    public static func relativeDayText(_ day: CalendarDay, today: CalendarDay) -> String {
        switch today.days(until: day) {
        case 0: return "Today"
        case -1: return "Yesterday"
        case 1: return "Tomorrow"
        default: return day.longDisplayText
        }
    }

    public static func timeText(_ moment: CalendarMoment) -> String {
        date(from: moment).formatted(date: .omitted, time: .shortened)
    }
}

/// The clock port, backed by the system clock.
public struct SystemClock: SankalpaClock {
    public init() {}
    public func now() -> CalendarMoment { AppTime.moment(from: Date()) }
}
