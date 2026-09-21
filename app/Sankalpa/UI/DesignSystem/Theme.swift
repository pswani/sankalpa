import SwiftUI
import SankalpaCore

/// The app's colour vocabulary.
///
/// One accent carries every interactive element. Action types and standings get their own muted
/// tints, but each of those is always paired with a distinct SF Symbol, so colour is never the only
/// thing carrying meaning.
enum Palette {
    /// A warm saffron. Used for interactive elements and the In progress state.
    static let accent = Color.adaptive(light: 0xB4651C, dark: 0xE8A04A)
    static let accentSoft = Color.adaptive(light: 0xF6EADC, dark: 0x3A2A17)

    /// The fill behind a filled button, and the label colour that sits on it.
    ///
    /// They are a pair because the readable combination flips between appearances: white on a deep
    /// saffron in Light Mode, near-black on a bright amber in Dark Mode. Using one accent for both
    /// would leave white text on light amber at roughly 2:1.
    static let accentFill = Color.adaptive(light: 0xA85A14, dark: 0xE8A04A)
    static let onAccentFill = Color.adaptive(light: 0xFFFFFF, dark: 0x201408)

    static let satisfied = Color.adaptive(light: 0x2E7D52, dark: 0x5FC98D)
    static let satisfiedSoft = Color.adaptive(light: 0xE2F1E8, dark: 0x16301F)

    static let missed = Color.adaptive(light: 0xB03A4B, dark: 0xF08096)
    static let missedSoft = Color.adaptive(light: 0xF8E6E9, dark: 0x3A1820)

    static let pausedTint = Color.adaptive(light: 0x8A6A1F, dark: 0xD9B75A)
    static let pausedSoft = Color.adaptive(light: 0xF6EFDB, dark: 0x332A14)

    static let meditation = Color.adaptive(light: 0x5B4B9E, dark: 0xA396E8)
    static let pranayama = Color.adaptive(light: 0x1F6F7A, dark: 0x6FCBD8)
    static let physical = Color.adaptive(light: 0xA85A22, dark: 0xF0A06A)
    static let observance = Color.adaptive(light: 0x8A4468, dark: 0xE092BA)

    /// Card backgrounds that sit on top of the grouped-list background.
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let hairline = Color.adaptive(light: 0xE4E0DA, dark: 0x38383A)
}

extension Color {
    /// A colour that resolves per appearance, so every screen works in Dark Mode without a second
    /// palette to keep in sync.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Domain styling

extension ActionType {
    var symbolName: String {
        switch self {
        case .meditation: return "figure.mind.and.body"
        case .pranayama: return "wind"
        case .physicalActivity: return "figure.run"
        case .observance: return "leaf.fill"
        }
    }

    var tint: Color {
        switch self {
        case .meditation: return Palette.meditation
        case .pranayama: return Palette.pranayama
        case .physicalActivity: return Palette.physical
        case .observance: return Palette.observance
        }
    }

    /// "Vipassana, Sahaj" — shown only as a hint while declaring.
    var exampleHint: String { exampleActivities.joined(separator: ", ") }
}

extension LifecycleState {
    var symbolName: String {
        switch self {
        case .notStarted: return "circle.dotted"
        case .inProgress: return "figure.walk.motion"
        case .paused: return "pause.circle.fill"
        case .completedSuccessfully: return "checkmark.seal.fill"
        case .completedUnsuccessfully: return "seal.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notStarted: return .secondary
        case .inProgress: return Palette.accent
        case .paused: return Palette.pausedTint
        case .completedSuccessfully: return Palette.satisfied
        case .completedUnsuccessfully: return Palette.missed
        case .stopped: return .secondary
        }
    }

    /// What this state means for the user, in one line, on the detail screen.
    var explanation: String {
        switch self {
        case .notStarted:
            return "Begin the sankalpa to start tracking and logging sessions."
        case .inProgress:
            return "Sessions can be logged. Each period is judged once it closes."
        case .paused:
            return "Nothing can be logged while paused. Periods keep their boundaries and the end date does not move."
        case .completedSuccessfully:
            return "You completed this sankalpa successfully. Only periods that closed before then were judged."
        case .completedUnsuccessfully:
            return "You completed this sankalpa unsuccessfully. Only periods that closed before then were judged."
        case .stopped:
            return "You stopped this sankalpa. Only periods that closed before then were judged."
        }
    }
}

extension PeriodStanding {
    var symbolName: String {
        switch self {
        case .open: return "circle.dashed"
        case .paused: return "pause.fill"
        case .satisfied: return "checkmark"
        case .unsatisfied: return "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .open: return .secondary
        case .paused: return Palette.pausedTint
        case .satisfied: return Palette.satisfied
        case .unsatisfied: return Palette.missed
        }
    }

    var softTint: Color {
        switch self {
        case .open: return Color(uiColor: .tertiarySystemFill)
        case .paused: return Palette.pausedSoft
        case .satisfied: return Palette.satisfiedSoft
        case .unsatisfied: return Palette.missedSoft
        }
    }
}
