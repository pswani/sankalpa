import SwiftUI
import SankalpaCore

/// The icon chip that identifies a sankalpa's action type everywhere it appears.
struct ActionChip: View {
    let actionType: ActionType
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: actionType.symbolName)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(actionType.tint)
            .frame(width: size, height: size)
            .background(actionType.tint.opacity(0.14), in: .rect(cornerRadius: size * 0.3))
            .accessibilityLabel(actionType.displayName)
    }
}

/// Lifecycle state, always as symbol plus words so the badge never relies on colour alone.
struct StateBadge: View {
    let state: LifecycleState

    var body: some View {
        Label(state.badgeText, systemImage: state.symbolName)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.tint.opacity(0.13), in: .capsule)
            .accessibilityLabel("Status: \(state.displayName)")
    }
}

/// Progress toward the period's minimum. It fills and stops at the minimum, because performing
/// more often than committed still just satisfies the period.
///
/// The ring carries the sankalpa's action-type tint until it is satisfied, which is the one place
/// those four colours do real work rather than decorating an icon.
struct PeriodProgressRing: View {
    let performed: Int
    let required: Int
    var tint: Color = Palette.accent
    var baseDiameter: CGFloat = 56
    var lineWidth: CGFloat = 6

    /// Grows with Dynamic Type, so the number inside does not stay small while everything around
    /// it scales. `@ScaledMetric` caps out sensibly rather than growing without limit.
    @ScaledMetric(relativeTo: .title3) private var scale: CGFloat = 1

    private var diameter: CGFloat { baseDiameter * min(scale, 1.5) }

    private var fraction: Double {
        guard required > 0 else { return 1 }
        return min(1, Double(performed) / Double(required))
    }

    private var isSatisfied: Bool { performed >= required }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(uiColor: .quaternaryLabel), lineWidth: lineWidth)
            // Nothing performed yet draws no arc at all; a rounded cap on a zero-length trim
            // leaves a dot that reads as a rendering fault.
            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        isSatisfied ? Palette.satisfied : tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: fraction)
            }

            if isSatisfied {
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.34, weight: .bold))
                    .foregroundStyle(Palette.satisfied)
                    .transition(.scale.combined(with: .opacity))
            } else {
                // The denominator rides along, so the ring reads on its own rather than depending
                // on the sentence beside it.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(performed)")
                        .font(.system(size: diameter * 0.36, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("/\(required)")
                        .font(.system(size: diameter * 0.22, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .foregroundStyle(.primary)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.snappy, value: isSatisfied)
        .accessibilityElement()
        .accessibilityLabel("Progress this period")
        .accessibilityValue("\(performed) of \(required) sessions")
    }
}

/// The last few closed periods as a row of small marks — enough to see momentum at a glance
/// without opening the sankalpa.
struct StandingStrip: View {
    let outcomes: [PeriodOutcome]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(outcomes) { outcome in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(outcome.standing == .open ? outcome.standing.softTint : outcome.standing.tint)
                    .frame(width: 14, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recent periods")
        .accessibilityValue(Self.summary(outcomes))
    }

    private static func summary(_ outcomes: [PeriodOutcome]) -> String {
        let tally = PeriodTally(outcomes: outcomes)
        return "\(tally.satisfied) satisfied, \(tally.unsatisfied) missed"
    }
}

/// One period's standing in a compact square, for the grid on the detail screen.
struct StandingTile: View {
    let outcome: PeriodOutcome

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: outcome.standing.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(outcome.standing.tint)
            Text("\(outcome.performed)/\(outcome.required)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 44, height: 44)
        .background(outcome.standing.softTint, in: .rect(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel(outcome.window.displayText)
        .accessibilityValue(
            "\(outcome.standing.displayName), \(outcome.performed) of \(outcome.required) performed"
        )
    }
}

/// A grouped card that matches the inset-grouped list look without forcing everything into a List.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 16))
    }
}

/// A section heading used outside of `List`, matching the weight of a grouped list header.
struct SectionHeading: View {
    let title: String
    var action: (title: String, handler: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let action {
                Button(action.title, action: action.handler)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// The counts of how closed periods turned out. Counts, not a score — the requirements
/// deliberately leave streaks and percentages out.
struct TallyRow: View {
    let tally: PeriodTally

    var body: some View {
        HStack(spacing: 10) {
            item(count: tally.satisfied, label: "Satisfied", standing: .satisfied)
            item(count: tally.unsatisfied, label: "Missed", standing: .unsatisfied)
            if tally.paused > 0 {
                item(count: tally.paused, label: "Paused", standing: .paused)
            }
        }
    }

    private func item(count: Int, label: String, standing: PeriodStanding) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(standing.tint)
            Label(label, systemImage: standing.symbolName)
                .font(.caption2)
                .labelStyle(.titleOnly)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(standing.softTint, in: .rect(cornerRadius: 12))
        .accessibilityElement()
        .accessibilityLabel("\(count) \(label.lowercased()) periods")
    }
}

/// The app's filled button: comfortably over the 44pt touch target, and readable in both
/// appearances because the fill and its label colour change together.
///
/// Callers set the width by putting `.frame(maxWidth: .infinity)` on their own label content, so
/// the same style works for a full-width card action and for a button in an empty state.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.onAccentFill)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(minHeight: 50)
            .background(
                Palette.accentFill.opacity(configuration.isPressed ? 0.82 : 1),
                in: .capsule
            )
            .contentShape(.capsule)
    }
}

/// The same shape as `PrimaryButtonStyle` with the fill taken away. Used for an action that is
/// still allowed but no longer the thing the screen is asking for — logging another session in a
/// period that is already satisfied, or a lifecycle change that is not the obvious next step.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(minHeight: 50)
            .background(tint.opacity(configuration.isPressed ? 0.20 : 0.12), in: .capsule)
            .contentShape(.capsule)
    }
}

/// Lets a view choose between button styles at runtime, which `ButtonStyle` otherwise forbids.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<Style: ButtonStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }

    static var primary: AnyButtonStyle { AnyButtonStyle(PrimaryButtonStyle()) }
    static var quiet: AnyButtonStyle { AnyButtonStyle(QuietButtonStyle()) }
    static func quiet(tint: Color) -> AnyButtonStyle { AnyButtonStyle(QuietButtonStyle(tint: tint)) }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    static func quiet(tint: Color) -> QuietButtonStyle { QuietButtonStyle(tint: tint) }
}
