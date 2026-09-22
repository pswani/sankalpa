import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

@Suite("Wire format")
struct WireFormatTests {

    // MARK: - Dates

    @Test("Reads and writes an ISO date")
    func dateRoundTrip() {
        #expect(WireFormat.day(from: "2026-09-21") == day(2026, 9, 21))
        #expect(WireFormat.text(day(2026, 9, 21)) == "2026-09-21")
        // Single-digit months and days are padded, which is what the service parses.
        #expect(WireFormat.text(day(2026, 1, 5)) == "2026-01-05")
    }

    @Test("Refuses a date that is not three numbers")
    func rejectsMalformedDate() {
        #expect(WireFormat.day(from: "2026-09") == nil)
        #expect(WireFormat.day(from: "not a date") == nil)
        #expect(WireFormat.day(from: "2026-13-01") == nil)
    }

    // MARK: - Moments

    /// Java's `ISO_LOCAL_DATE_TIME` drops zero seconds and prints sub-second digits when the clock
    /// has them, so all three shapes come off the wire in practice.
    static let momentShapes: [(text: String, expectedSecondOfDay: Int)] = [
        ("2026-09-21T22:30", 81_000),          // 22:30:00 — the service drops zero seconds
        ("2026-09-21T22:30:41", 81_041),
        ("2026-09-21T22:30:32.064596", 81_032) // sub-second digits are read and discarded
    ]

    @Test("Reads every shape the service sends", arguments: momentShapes)
    func readsMomentShapes(text: String, expectedSecondOfDay: Int) {
        let parsed = WireFormat.moment(from: text)
        #expect(parsed?.day == day(2026, 9, 21))
        #expect(parsed?.secondOfDay == expectedSecondOfDay)
    }

    @Test("Always writes seconds, which the service parses either way")
    func writesMomentWithSeconds() {
        let subject = CalendarMoment(day: day(2026, 9, 21), hour: 6, minute: 5, second: 0)
        #expect(WireFormat.text(subject) == "2026-09-21T06:05:00")
    }

    @Test("A written moment reads back unchanged")
    func momentRoundTrip() {
        let subject = CalendarMoment(day: day(2028, 2, 29), hour: 23, minute: 59, second: 59)
        #expect(WireFormat.moment(from: WireFormat.text(subject)) == subject)
    }

    @Test("Refuses a malformed moment")
    func rejectsMalformedMoment() {
        #expect(WireFormat.moment(from: "2026-09-21") == nil)
        #expect(WireFormat.moment(from: "2026-09-21T25:00:00") == nil)
        #expect(WireFormat.moment(from: "2026-09-21Tnoon") == nil)
    }

    /// Nothing here may route through `Date`: a zone-free value that goes to an instant and back
    /// is where an off-by-one day comes from. Midnight is where that would show.
    @Test("Midnight keeps its own day")
    func midnightKeepsItsDay() {
        let parsed = WireFormat.moment(from: "2026-09-21T00:00:00")
        #expect(parsed?.day == day(2026, 9, 21))
        #expect(parsed?.secondOfDay == 0)
    }
}
