import SwiftUI
import SankalpaCore
import SankalpaStorage

enum Ink {
    static let accent = adaptive(0x315B46, 0xA8D3B5)
    static let onAccent = adaptive(0xFFFFFF, 0x163323)
    static let paper = adaptive(0xF7F6F0, 0x121914)
    static let card = adaptive(0xFFFFFF, 0x1D2820)
    static let wash = adaptive(0xE9EFE7, 0x283C2E)
    static let warm = adaptive(0x966331, 0xE0B887)
    static let danger = adaptive(0xA13F47, 0xF2A3AA)
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}
extension ActionType {
    var symbol: String {
        switch self {
        case .meditation: "sun.horizon"
        case .pranayama: "wind"
        case .physicalActivity: "figure.walk"
        case .observance: "leaf"
        }
    }
}
extension LifecycleState {
    var symbol: String {
        switch self {
        case .notStarted: "circle.dotted"
        case .inProgress: "circle.lefthalf.filled"
        case .paused: "pause.circle"
        case .completedSuccessfully: "checkmark.seal"
        case .completedUnsuccessfully: "minus.circle"
        case .stopped: "stop.circle"
        }
    }
}
struct Status: View {
    let state: LifecycleState
    var body: some View {
        Label(state.displayName, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state == .paused ? Ink.warm : Ink.accent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Ink.wash, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel("Status: \(state.displayName)")
            .accessibilityIdentifier("status-\(state.rawValue)")
    }
}
struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).background(Ink.card, in: RoundedRectangle(cornerRadius: 24))
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Ink.accent)
    }
}
struct FilledButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.labelStyle(.titleOnly).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
            .padding(.horizontal, 18).padding(.vertical, 15)
            .foregroundStyle(enabled ? Ink.onAccent : Color.secondary)
            .background(enabled ? Ink.accent.opacity(configuration.isPressed ? 0.8 : 1) : Ink.wash, in: RoundedRectangle(cornerRadius: 16))
            .frame(minHeight: 48)
    }
}
struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium)).frame(maxWidth: .infinity)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .foregroundStyle(Ink.accent)
            .background(Ink.wash.opacity(configuration.isPressed ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 16))
            .frame(minHeight: 44)
    }
}
struct PracticeProgress: View {
    let progress: CurrentPeriodProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.isSatisfied ? "Commitment met" : "\(progress.remaining) to go")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(progress.performed) / \(progress.required)").font(.subheadline.monospacedDigit())
            }
            ProgressView(value: progress.fraction).tint(Ink.accent).accessibilityHidden(true)
            Text(progress.window.displayText).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
struct MonthPicker: View {
    @Binding var month: CalendarDay
    let oldest: CalendarDay
    let today: CalendarDay
    private var first: CalendarDay { CalendarDay(year: month.year, month: month.month, day: 1)! }
    var body: some View {
        HStack {
            Button { month = first.addingMonths(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Previous month").disabled(first <= CalendarDay(year: oldest.year, month: oldest.month, day: 1)!)
            Spacer(minLength: 4)
            Text(AppTime.date(from: first).formatted(.dateTime.month(.wide).year())).font(.headline).multilineTextAlignment(.center)
            Spacer(minLength: 4)
            Button { month = first.addingMonths(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("Next month").disabled(first.addingMonths(1) > today)
        }
    }
}
struct EmptyPractice: View {
    let title: String
    let message: String
    var symbol = "leaf"
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(Ink.accent).accessibilityHidden(true)
            Text(title).font(.title2.weight(.medium)).fontDesign(.serif)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 20)
    }
}
