import Foundation

/// S4 — the minimum number of sessions that satisfies one period. Performing the action more often
/// than committed still satisfies the period, so this is a floor, never a cap.
public struct TimesPerPeriod: Hashable, Codable, Sendable {
    public static let maxValue = 99

    public let value: Int

    public init(_ value: Int) throws(DeclarationError) {
        guard value >= 1, value <= TimesPerPeriod.maxValue else {
            throw .invalidTimesPerPeriod(value)
        }
        self.value = value
    }
}

/// S5 — duration exists only as a whole number of periods, so no invalid duration shape can be
/// represented. A six-month commitment with a Week period is 26 weeks.
public struct PeriodCount: Hashable, Codable, Sendable {
    public static let maxValue = 3_650

    public let value: Int

    public init(_ value: Int) throws(DeclarationError) {
        guard value >= 1, value <= PeriodCount.maxValue else {
            throw .invalidPeriodCount(value)
        }
        self.value = value
    }
}
