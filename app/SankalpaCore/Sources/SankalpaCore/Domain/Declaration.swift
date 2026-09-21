import Foundation

/// The raw input for declaring a sankalpa. Values are validated into value objects by
/// `Sankalpa.declare`, so no partially valid sankalpa can exist.
public struct Declaration: Sendable {
    public let title: String
    public let description: String
    public let actionType: ActionType
    public let startDate: CalendarDay
    public let periodUnit: PeriodUnit
    public let timesPerPeriod: Int
    /// Absent when the sankalpa is tracked until it is stopped.
    public let periodCount: Int?

    public init(
        title: String,
        description: String = "",
        actionType: ActionType,
        startDate: CalendarDay,
        periodUnit: PeriodUnit,
        timesPerPeriod: Int,
        periodCount: Int? = nil
    ) {
        self.title = title
        self.description = description
        self.actionType = actionType
        self.startDate = startDate
        self.periodUnit = periodUnit
        self.timesPerPeriod = timesPerPeriod
        self.periodCount = periodCount
    }
}
