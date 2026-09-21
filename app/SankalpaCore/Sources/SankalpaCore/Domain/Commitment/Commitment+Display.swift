import Foundation

extension Commitment {
    /// "Once a day", "Twice a week", "4 times a month"
    public var frequencyPhrase: String {
        let times = timesPerPeriod.value
        let countWord: String
        switch times {
        case 1: countWord = "Once"
        case 2: countWord = "Twice"
        default: countWord = "\(times) times"
        }
        return "\(countWord) \(periodUnit.perPhrase)"
    }

    /// "for 26 weeks" / "until you stop it"
    public var durationPhrase: String {
        guard let periodCount else { return "until you stop it" }
        return "for \(periodCount.value) \(periodUnit.pluralName(periodCount.value))"
    }

    /// The duration on its own: "180 days" or "Ongoing".
    public var durationValueText: String {
        guard let periodCount else { return "Ongoing" }
        return "\(periodCount.value) \(periodUnit.pluralName(periodCount.value))"
    }

    /// "Once a day for 180 days" / "4 times a week · ongoing"
    public var fullPhrase: String {
        periodCount == nil
            ? "\(frequencyPhrase) · ongoing"
            : "\(frequencyPhrase) \(durationPhrase)"
    }

    /// "4× a week", for tight spaces such as list rows.
    public var compactFrequencyPhrase: String {
        "\(timesPerPeriod.value)× \(periodUnit.perPhrase)"
    }
}
