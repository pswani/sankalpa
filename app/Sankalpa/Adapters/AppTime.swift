import Foundation
import SankalpaCore

/// The one place instants become dates.
///
/// The domain works in wall-clock terms with no time zone attached, so a period boundary can never
/// be moved by a daylight-saving shift. This adapter is the boundary where the system clock and the
/// UI's `Date` values are interpreted, using the single configured application time zone
/// (09-open-questions Q1). No per-user or per-sankalpa zone is modelled.
enum AppTime {
    /// Changing this changes how every instant is bucketed into days, so it is read once.
    static let timeZone: TimeZone = .autoupdatingCurrent

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func moment(from date: Date) -> CalendarMoment {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return CalendarMoment(
            day: CalendarDay(
                year: parts.year ?? 1970,
                clampedMonth: parts.month ?? 1,
                day: parts.day ?? 1
            ),
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: parts.second ?? 0
        )
    }

    static func day(from date: Date) -> CalendarDay { moment(from: date).day }

    static func date(from moment: CalendarMoment) -> Date {
        var parts = DateComponents()
        parts.year = moment.day.year
        parts.month = moment.day.month
        parts.day = moment.day.day
        parts.hour = moment.hour
        parts.minute = moment.minute
        return calendar.date(from: parts) ?? Date()
    }

    static func date(from day: CalendarDay) -> Date {
        date(from: CalendarMoment.startOfDay(day))
    }

    /// "Today", "Yesterday", or the date — for journal and session-list headers.
    static func relativeDayText(_ day: CalendarDay, today: CalendarDay) -> String {
        switch today.days(until: day) {
        case 0: return "Today"
        case -1: return "Yesterday"
        case 1: return "Tomorrow"
        default: return day.longDisplayText
        }
    }

    static func timeText(_ moment: CalendarMoment) -> String {
        date(from: moment).formatted(date: .omitted, time: .shortened)
    }
}

private extension CalendarDay {
    /// Foundation always hands back a real calendar date, so this only guards against a malformed
    /// `DateComponents` rather than doing any domain rounding.
    init(year: Int, clampedMonth month: Int, day: Int) {
        self.init(year: year, month: month, clampedDay: day)
    }
}

/// The clock port, backed by the system clock.
struct SystemClock: SankalpaClock {
    func now() -> CalendarMoment { AppTime.moment(from: Date()) }
}
