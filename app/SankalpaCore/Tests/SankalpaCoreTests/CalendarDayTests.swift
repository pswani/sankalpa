import Testing
@testable import SankalpaCore

@Suite("CalendarDay")
struct CalendarDayTests {

    @Test("Serial numbers round-trip across leap years and century boundaries")
    func serialRoundTrip() {
        for candidate in [day(1970, 1, 1), day(2000, 2, 29), day(1900, 3, 1), day(2024, 2, 29), day(2026, 12, 31)] {
            #expect(CalendarDay(serialNumber: candidate.serialNumber) == candidate)
        }
        #expect(day(1970, 1, 1).serialNumber == 0)
        #expect(day(1970, 1, 2).serialNumber == 1)
        #expect(day(1969, 12, 31).serialNumber == -1)
    }

    @Test("Rejects dates that do not exist")
    func rejectsImpossibleDates() {
        #expect(CalendarDay(year: 2026, month: 2, day: 29) == nil)
        #expect(CalendarDay(year: 2026, month: 13, day: 1) == nil)
        #expect(CalendarDay(year: 2024, month: 2, day: 29) != nil)
    }

    @Test("Adding months clamps to the last valid day")
    func monthClamping() {
        #expect(day(2026, 1, 31).addingMonths(1) == day(2026, 2, 28))
        #expect(day(2024, 1, 31).addingMonths(1) == day(2024, 2, 29))
        #expect(day(2026, 1, 31).addingMonths(3) == day(2026, 4, 30))
        #expect(day(2026, 12, 31).addingMonths(1) == day(2027, 1, 31))
        #expect(day(2026, 3, 31).addingMonths(-1) == day(2026, 2, 28))
    }

    @Test("Adding years clamps February 29 in common years")
    func yearClamping() {
        #expect(day(2024, 2, 29).addingYears(1) == day(2025, 2, 28))
        #expect(day(2024, 2, 29).addingYears(4) == day(2028, 2, 29))
    }

    @Test("Day differences span month and year boundaries")
    func dayDifferences() {
        #expect(day(2026, 1, 1).days(until: day(2026, 1, 8)) == 7)
        #expect(day(2026, 1, 1).days(until: day(2027, 1, 1)) == 365)
        #expect(day(2024, 1, 1).days(until: day(2025, 1, 1)) == 366)
    }
}
