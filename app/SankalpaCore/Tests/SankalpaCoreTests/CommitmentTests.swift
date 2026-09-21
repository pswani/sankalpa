import Testing
@testable import SankalpaCore

@Suite("Commitment")
struct CommitmentTests {

    private func commitment(
        start: CalendarDay,
        unit: PeriodUnit,
        perPeriod: Int = 1,
        count: Int? = nil
    ) -> Commitment {
        Commitment(
            startDate: start,
            periodUnit: unit,
            timesPerPeriod: times(perPeriod),
            periodCount: count.map { periods($0) }
        )
    }

    // MARK: - End date (S6, DD-12)

    @Test("One day beginning January 1 ends January 1")
    func singleDayEndDate() {
        let subject = commitment(start: day(2026, 1, 1), unit: .day, count: 1)
        #expect(subject.endDate == day(2026, 1, 1))
    }

    @Test("One week beginning January 1 ends January 7")
    func singleWeekEndDate() {
        let subject = commitment(start: day(2026, 1, 1), unit: .week, count: 1)
        #expect(subject.endDate == day(2026, 1, 7))
    }

    @Test("A six-month commitment expressed as 26 weeks ends 182 days after it starts")
    func twentySixWeeks() {
        let subject = commitment(start: day(2026, 1, 1), unit: .week, count: 26)
        #expect(subject.endDate == day(2026, 7, 1))
        #expect(subject.startDate.days(until: subject.endDate!) == 181)
    }

    @Test("Vipassana twice a day for six months, as 180 days")
    func vipassanaExample() {
        let subject = commitment(start: day(2026, 1, 1), unit: .day, perPeriod: 2, count: 180)
        #expect(subject.endDate == day(2026, 6, 29))
        #expect(subject.timesPerPeriod.value == 2)
    }

    @Test("No duration means no end date and coverage that never lapses")
    func indefiniteCommitment() {
        let subject = commitment(start: day(2026, 1, 1), unit: .week, perPeriod: 4)
        #expect(subject.endDate == nil)
        #expect(subject.isIndefinite)
        #expect(subject.covers(day(2099, 1, 1)))
        #expect(!subject.covers(day(2025, 12, 31)))
    }

    // MARK: - Boundary anchoring (DD-12)

    @Test("Monthly boundaries stay anchored to January 31 instead of drifting to the 28th")
    func monthlyBoundariesDoNotDrift() {
        let subject = commitment(start: day(2026, 1, 31), unit: .month, count: 4)
        let starts = (0..<4).map { subject.window(at: $0)!.start }
        #expect(starts == [day(2026, 1, 31), day(2026, 2, 28), day(2026, 3, 31), day(2026, 4, 30)])
        #expect(subject.endDate == day(2026, 5, 30))
    }

    @Test("A February 29 yearly commitment returns to February 29 in the next leap year")
    func yearlyBoundariesReturnToLeapDay() {
        let subject = commitment(start: day(2024, 2, 29), unit: .year, count: 5)
        let starts = (0..<5).map { subject.window(at: $0)!.start }
        #expect(starts == [
            day(2024, 2, 29), day(2025, 2, 28), day(2026, 2, 28), day(2027, 2, 28), day(2028, 2, 29)
        ])
    }

    // MARK: - Windows

    @Test("Windows are inclusive and contiguous")
    func windowsAreContiguous() {
        let subject = commitment(start: day(2026, 1, 1), unit: .week, count: 4)
        for index in 0..<3 {
            let current = subject.window(at: index)!
            let next = subject.window(at: index + 1)!
            #expect(current.end.addingDays(1) == next.start)
            #expect(current.dayCount == 7)
        }
        #expect(subject.window(at: 4) == nil)
    }

    @Test("windowContaining finds the right window despite month clamping")
    func windowContainingHandlesClamping() {
        let subject = commitment(start: day(2026, 1, 31), unit: .month, count: 6)
        #expect(subject.windowContaining(day(2026, 2, 27))?.index == 0)
        #expect(subject.windowContaining(day(2026, 2, 28))?.index == 1)
        #expect(subject.windowContaining(day(2026, 3, 30))?.index == 1)
        #expect(subject.windowContaining(day(2026, 3, 31))?.index == 2)
        #expect(subject.windowContaining(day(2025, 12, 31)) == nil)
    }

    @Test("windowsStartingBetween returns only windows starting inside the range")
    func rangeBoundedWindows() {
        let subject = commitment(start: day(2026, 1, 1), unit: .day, count: 100)
        let selected = subject.windowsStartingBetween(day(2026, 1, 10), day(2026, 1, 14))
        #expect(selected.map(\.index) == [9, 10, 11, 12, 13])

        // A range that starts mid-window still excludes that window, because selection is by start
        // date — the application widens the session query instead (DD-17).
        let weekly = commitment(start: day(2026, 1, 1), unit: .week, count: 10)
        let midWeek = weekly.windowsStartingBetween(day(2026, 1, 3), day(2026, 1, 20))
        #expect(midWeek.map(\.start) == [day(2026, 1, 8), day(2026, 1, 15)])
    }

    @Test("Coverage is inclusive at both ends")
    func coverageIsInclusive() {
        let subject = commitment(start: day(2026, 1, 1), unit: .day, count: 10)
        #expect(subject.covers(day(2026, 1, 1)))
        #expect(subject.covers(day(2026, 1, 10)))
        #expect(!subject.covers(day(2026, 1, 11)))
        #expect(!subject.covers(day(2025, 12, 31)))
    }
}
