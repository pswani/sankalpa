import SwiftUI
import SankalpaCore
import SankalpaStorage

/// Every period, newest first, with the arithmetic that produced each standing.
struct PeriodHistoryView: View {
    @Environment(AppModel.self) private var model
    let summary: SankalpaSummary

    /// Newest first: the period that just closed is the one the user came to check.
    private var outcomes: [PeriodOutcome] {
        model.recentPeriodOutcomes(summary.id, limit: 400).reversed()
    }

    var body: some View {
        Group {
            if outcomes.isEmpty {
                ContentUnavailableView(
                    "No closed periods yet",
                    systemImage: "square.grid.2x2",
                    description: Text("A period is judged only once it has closed.")
                )
            } else {
                List {
                    Section {
                        TallyRow(tally: model.periodTally(summary.id))
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                    .listSectionSpacing(.compact)

                    Section {
                        ForEach(outcomes) { outcome in
                            PeriodOutcomeRow(outcome: outcome)
                        }
                    } footer: {
                        Text(footnote)
                    }
                }
            }
        }
        .navigationTitle("Periods")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footnote: String {
        if summary.state.isTerminal {
            return "Only periods that closed before you \(summary.state == .stopped ? "stopped" : "completed") this sankalpa are judged. The period you were in and any after it are not shown."
        }
        return "A period is judged once it closes. Performing more often than committed still satisfies it."
    }
}

struct PeriodOutcomeRow: View {
    let outcome: PeriodOutcome

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: outcome.standing.symbolName)
                .font(.footnote.weight(.bold))
                .foregroundStyle(outcome.standing.tint)
                .frame(width: 28, height: 28)
                .background(outcome.standing.softTint, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.window.displayText)
                    .font(.subheadline.weight(.medium))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(outcome.standing.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(outcome.standing.tint)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        switch outcome.standing {
        case .paused:
            return "Paused for the whole period — neither satisfied nor missed"
        case .open:
            return "\(outcome.performed) of \(outcome.required) so far"
        case .satisfied:
            return outcome.exceededCommitment
                ? "\(outcome.performed) performed, \(outcome.required) committed"
                : "\(outcome.performed) of \(outcome.required) performed"
        case .unsatisfied:
            return "\(outcome.performed) of \(outcome.required) performed — missed \(outcome.missed)"
        }
    }
}

/// Every logged session, grouped by the day it was performed.
struct SessionHistoryView: View {
    @Environment(AppModel.self) private var model
    let summary: SankalpaSummary

    private var grouped: [(day: CalendarDay, sessions: [Session])] {
        let sessions = model.recentSessions(summary.id, days: 3650)
        return Dictionary(grouping: sessions, by: { $0.occurredAt.day })
            .map { (day: $0.key, sessions: $0.value.sorted { $0.occurredAt > $1.occurredAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        Group {
            if grouped.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "checkmark.circle",
                    description: Text("Sessions you log will be listed here.")
                )
            } else {
                List {
                    ForEach(grouped, id: \.day) { group in
                        Section(AppTime.relativeDayText(group.day, today: model.today)) {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session, today: model.today, showsDate: false)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The lifecycle audit trail. Both timestamps are shown, because they differ for a backdated Begin
/// and that difference is the audit fact.
struct LifecycleHistoryView: View {
    @Environment(AppModel.self) private var model
    let summary: SankalpaSummary

    private var transitions: [LifecycleTransition] { model.lifecycleHistory(summary.id) }

    var body: some View {
        Group {
            if transitions.isEmpty {
                ContentUnavailableView(
                    "Nothing has changed yet",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("This sankalpa is still Not started. Every change you make will be recorded here.")
                )
            } else {
                List {
                    Section {
                        ForEach(Array(transitions.enumerated()), id: \.offset) { _, transition in
                            TransitionRow(transition: transition, today: model.today)
                        }
                    } footer: {
                        Text("Beginning can be backdated, so its effective time may differ from when it was recorded. Every other change takes effect when it is made.")
                    }
                }
            }
        }
        .navigationTitle("Transition history")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TransitionRow: View {
    let transition: LifecycleTransition
    let today: CalendarDay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(transition.from.badgeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Label(transition.to.badgeText, systemImage: transition.to.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(transition.to.tint)
            }

            LabeledContent("Took effect") {
                Text(momentText(transition.effectiveAt))
            }
            .font(.footnote)

            if transition.wasBackdated {
                LabeledContent("Recorded") {
                    Text(momentText(transition.recordedAt))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Label("Backdated", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func momentText(_ moment: CalendarMoment) -> String {
        "\(AppTime.relativeDayText(moment.day, today: today)) at \(AppTime.timeText(moment))"
    }
}
