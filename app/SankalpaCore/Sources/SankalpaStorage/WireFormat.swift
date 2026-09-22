import Foundation
import SankalpaCore

/// Translation between the domain's zone-free calendar types and the REST API's ISO-8601 strings.
///
/// The service sends `LocalDate` and `LocalDateTime` — wall-clock values with no offset, which is
/// exactly what `CalendarDay` and `CalendarMoment` already are. So this is a pure string/component
/// translation with no time zone anywhere in it. Nothing here calls `Date`, `Calendar` or
/// `DateFormatter`: routing a zone-free value through `Date` would attach a zone and then remove
/// it again, and the round trip is where an off-by-one day comes from.
///
/// Both ends interpret these values in one configured zone — the device's for the app
/// (`AppTime.timeZone`), `SANKALPA_TIMEZONE` for the service. The deployment has to set them to
/// the same zone; nothing in the format can check that.
enum WireFormat {

    // MARK: - Decoding

    /// `2026-09-21`
    static func day(from text: String) -> CalendarDay? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }

    /// `2026-09-21T22:30:41`, `2026-09-21T22:30` or `2026-09-21T22:30:32.064596`.
    ///
    /// All three shapes are real: Java's `ISO_LOCAL_DATE_TIME` drops the seconds when they are
    /// zero and prints sub-second digits when the clock has them. Fractional seconds are read and
    /// discarded, because `CalendarMoment` has one-second resolution.
    static func moment(from text: String) -> CalendarMoment? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, let day = day(from: String(halves[0])) else { return nil }

        let time = halves[1].split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(time.count),
              let hour = Int(time[0]), let minute = Int(time[1])
        else { return nil }

        var second = 0
        if time.count == 3 {
            // Drop any fractional part before reading the whole seconds.
            let whole = time[2].split(separator: ".", omittingEmptySubsequences: false)[0]
            guard let parsed = Int(whole) else { return nil }
            second = parsed
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        // A leap second lands on the last representable moment of the day rather than rolling over.
        return CalendarMoment(day: day, hour: hour, minute: minute, second: min(second, 59))
    }

    // MARK: - Encoding

    static func text(_ day: CalendarDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    /// Always written with seconds, which `ISO_LOCAL_DATE_TIME` parses whether or not they are zero.
    static func text(_ moment: CalendarMoment) -> String {
        String(
            format: "%@T%02d:%02d:%02d",
            text(moment.day),
            moment.secondOfDay / 3600,
            (moment.secondOfDay % 3600) / 60,
            moment.secondOfDay % 60
        )
    }
}
