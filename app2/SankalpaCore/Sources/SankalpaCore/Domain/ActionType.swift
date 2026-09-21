import Foundation

/// S2 — exactly the four values the requirements name. The example activities (Vipassana, Gym,
/// Sudarshan Kriya) stay examples; they are not catalogue data (see 01-strategic-design).
public enum ActionType: String, CaseIterable, Codable, Sendable {
    case meditation
    case pranayama
    case physicalActivity
    case observance

    public var displayName: String {
        switch self {
        case .meditation: return "Meditation"
        case .pranayama: return "Pranayama"
        case .physicalActivity: return "Physical Activity"
        case .observance: return "Observance"
        }
    }

    /// Illustrative only — shown as placeholder hints when declaring, never stored.
    public var exampleActivities: [String] {
        switch self {
        case .meditation: return ["Vipassana", "Sahaj"]
        case .pranayama: return ["Sudarshan Kriya", "1:2 Nadishodhan", "142 Pranayama"]
        case .physicalActivity: return ["Gym", "Walk", "Run", "Padmasadhana", "Suryanamaskara"]
        case .observance: return ["Brahmacharya", "Dream journaling"]
        }
    }
}
