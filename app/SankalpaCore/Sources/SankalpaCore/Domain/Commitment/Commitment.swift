import Foundation

/// "x times per y period for z duration", kept together because the end date and every period
/// window are derived from these values as a set (DD-3).
public struct Commitment: Hashable, Codable, Sendable {
    public let startDate: CalendarDay
    public let periodUnit: PeriodUnit
    public let timesPerPeriod: TimesPerPeriod
    /// Absent when the sankalpa is observed until it is stopped.
    public let periodCount: PeriodCount?

    public init(
        startDate: CalendarDay,
        periodUnit: PeriodUnit,
        timesPerPeriod: TimesPerPeriod,
        periodCount: PeriodCount? = nil
    ) {
        self.startDate = startDate
        self.periodUnit = periodUnit
        self.timesPerPeriod = timesPerPeriod
        self.periodCount = periodCount
    }

    public var isIndefinite: Bool { periodCount == nil }

    // MARK: - Derived coverage

    /// S6 — the inclusive last covered date, derived rather than stored, so pausing can never
    /// extend it. For `n` periods it is the start of period `n` (zero-based index `n`) minus a day.
    public var endDate: CalendarDay? {
        guard let periodCount else { return nil }
        return periodUnit.boundary(from: startDate, index: periodCount.value).addingDays(-1)
    }

    public func covers(_ day: CalendarDay) -> Bool {
        guard day >= startDate else { return false }
        guard let endDate else { return true }
        return day <= endDate
    }

    public func covers(_ moment: CalendarMoment) -> Bool {
        covers(moment.day)
    }

    // MARK: - Period windows

    public var totalWindowCount: Int? { periodCount?.value }

    public func window(at index: Int) -> PeriodWindow? {
        guard index >= 0 else { return nil }
        if let total = totalWindowCount, index >= total { return nil }
        let start = periodUnit.boundary(from: startDate, index: index)
        let end = periodUnit.boundary(from: startDate, index: index + 1).addingDays(-1)
        return PeriodWindow(index: index, unit: periodUnit, start: start, end: end)
    }

    public func windowContaining(_ day: CalendarDay) -> PeriodWindow? {
        guard covers(day) else { return nil }
        return window(at: index(containing: day))
    }

    public func windowContaining(_ moment: CalendarMoment) -> PeriodWindow? {
        windowContaining(moment.day)
    }

    /// Every window whose *start date* falls in `from...until`, in order (DD-17). The caller keeps
    /// this bounded so an indefinite daily commitment never materialises its whole history.
    public func windowsStartingBetween(_ from: CalendarDay, _ until: CalendarDay) -> [PeriodWindow] {
        guard from <= until, until >= startDate else { return [] }
        var index = index(containing: max(from, startDate))
        if periodUnit.boundary(from: startDate, index: index) < from { index += 1 }

        var windows: [PeriodWindow] = []
        while let window = window(at: index), window.start <= until {
            windows.append(window)
            index += 1
        }
        return windows
    }

    /// The index of the window covering `day`, corrected from an estimate so that month and year
    /// clamping cannot put it off by one.
    private func index(containing day: CalendarDay) -> Int {
        var index = max(0, periodUnit.estimatedIndex(from: startDate, to: day))
        while index > 0, periodUnit.boundary(from: startDate, index: index) > day {
            index -= 1
        }
        while periodUnit.boundary(from: startDate, index: index + 1) <= day {
            index += 1
        }
        return index
    }
}
