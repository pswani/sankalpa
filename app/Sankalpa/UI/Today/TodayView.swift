import SwiftUI
import SankalpaCore

/// One purpose: show what is open today and make logging a session a single tap.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    var onDeclare: () -> Void
    /// Today has nothing to show once everything is finished, but the finished ones are still
    /// there — this is the way to them.
    var onShowFinished: () -> Void

    @State private var path: [SankalpaId] = []
    @State private var loggingFor: SankalpaSummary?
    /// Shown once. The app's vocabulary — declare, begin, period, satisfied — is worth one short
    /// introduction rather than leaving it to be inferred.
    @AppStorage("hasSeenIntroduction") private var hasSeenIntroduction = false

    private var inProgress: [SankalpaSummary] {
        model.activeSummaries.filter { $0.state == .inProgress }
    }
    private var paused: [SankalpaSummary] {
        model.activeSummaries.filter { $0.state == .paused }
    }
    private var notStarted: [SankalpaSummary] {
        model.activeSummaries.filter { $0.state == .notStarted }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.activeSummaries.isEmpty {
                    emptyState
                } else {
                    board
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Declare a sankalpa", systemImage: "plus", action: onDeclare)
                }
            }
            .navigationDestination(for: SankalpaId.self) { id in
                SankalpaDetailView(sankalpaId: id)
            }
            .sheet(item: $loggingFor) { summary in
                LogSessionView(summary: summary)
            }
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(model.today.longDisplayText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                if !hasSeenIntroduction {
                    IntroductionCard {
                        withAnimation(.snappy) { hasSeenIntroduction = true }
                    }
                }

                if !inProgress.isEmpty {
                    section(
                        title: pendingCount == 0
                            ? "All caught up for now"
                            : "\(pendingCount) still open",
                        summaries: inProgress
                    )
                }
                if !paused.isEmpty {
                    section(title: "Paused", summaries: paused)
                }
                if !notStarted.isEmpty {
                    section(title: "Waiting to begin", summaries: notStarted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// How many in-progress sankalpas still need a session in their current period.
    private var pendingCount: Int {
        inProgress.count { ($0.currentPeriod?.isSatisfied ?? true) == false }
    }

    private func section(title: String, summaries: [SankalpaSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: title)
            ForEach(summaries) { summary in
                TodayCard(
                    summary: summary,
                    onOpen: { path.append(summary.id) },
                    onLogAtTime: { loggingFor = summary }
                )
            }
        }
    }

    /// "No sankalpas yet" is only true of an empty app. Once everything has been completed or
    /// stopped there is a practice to look back on, and saying otherwise erases it.
    @ViewBuilder
    private var emptyState: some View {
        if model.summaries.isEmpty {
            ContentUnavailableView {
                Label("No sankalpas yet", systemImage: "seal")
            } description: {
                Text("A sankalpa is a declared intent with a commitment to act — so many times, per period, for a duration.")
            } actions: {
                Button("Declare a sankalpa", action: onDeclare)
                    .buttonStyle(.primary)
            }
        } else {
            ContentUnavailableView {
                Label("No active sankalpas", systemImage: "checkmark.seal")
            } description: {
                Text("Every sankalpa has been completed or stopped. Declare another, or look back over the finished ones.")
            } actions: {
                VStack(spacing: 10) {
                    Button("Declare a sankalpa", action: onDeclare)
                        .buttonStyle(.primary)
                    Button("See finished sankalpas", action: onShowFinished)
                        .buttonStyle(.quiet)
                }
            }
        }
    }
}

/// One sankalpa on the Today board: what it is, how the current period is going, and the one
/// action that matters right now.
private struct TodayCard: View {
    @Environment(AppModel.self) private var model
    let summary: SankalpaSummary
    var onOpen: () -> Void
    var onLogAtTime: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                Button(action: onOpen) { header }
                    .buttonStyle(.plain)
                    .padding(16)

                Divider().background(Palette.hairline)

                actionRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    private var header: some View {
        // At accessibility sizes the icon and the progress ring stop flanking the text and sit
        // above and below it, so the title has the whole card width instead of a column too
        // narrow to hold "Sudarshan Kriya" without hyphenating it.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))

        return layout {
            ActionChip(actionType: summary.actionType)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(summary.commitment.frequencyPhrase)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let period = summary.currentPeriod {
                    Text(period.progressPhrase)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(period.isSatisfied ? Palette.satisfied : .secondary)
                    // "This week" is not the calendar week — every window is anchored to the
                    // sankalpa's own start date. Where that can differ, the card says which days
                    // it means.
                    if period.window.dayCount > 1 {
                        Text(period.window.displayText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(outOfPeriodText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // How the last few closed periods went, so the card answers "how am I doing"
                // and not only "what is open".
                let recent = model.recentClosedOutcomes(summary.id)
                if !recent.isEmpty {
                    StandingStrip(outcomes: recent)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let period = summary.currentPeriod, summary.state == .inProgress {
                PeriodProgressRing(
                    performed: period.performed,
                    required: period.required,
                    tint: summary.actionType.tint
                )
            } else {
                StateBadge(state: summary.state)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the sankalpa")
    }

    private var outOfPeriodText: String {
        if summary.state == .notStarted {
            return "Starts \(summary.commitment.startDate.longDisplayText)"
        }
        if let endDate = summary.commitment.endDate, model.today > endDate {
            return "Ended \(endDate.longDisplayText)"
        }
        return summary.commitment.durationValueText
    }

    @ViewBuilder
    private var actionRow: some View {
        switch summary.state {
        case .inProgress:
            // Once the period is satisfied the action is still available, but it stops being the
            // thing the screen is asking for — so it loses the fill.
            let satisfied = summary.currentPeriod?.isSatisfied ?? false
            HStack(spacing: 8) {
                Button {
                    _ = model.logSession(summary.id, occurredAt: model.now())
                } label: {
                    Label(
                        satisfied ? "Log another" : "Log a session",
                        systemImage: "checkmark.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(satisfied ? AnyButtonStyle(.quiet) : AnyButtonStyle(.primary))
                .disabled(summary.currentPeriod == nil)

                Button(action: onLogAtTime) {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Log a session at another time")
            }
        case .paused:
            Button {
                model.resume(summary.id)
            } label: {
                Text("Resume").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
        case .notStarted:
            if summary.commitment.startDate > model.today {
                Label(
                    "Begins \(summary.commitment.startDate.longDisplayText)",
                    systemImage: "calendar"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            } else {
                Button {
                    model.begin(summary.id)
                } label: {
                    Text("Begin").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
            }
        default:
            EmptyView()
        }
    }
}

/// A one-time introduction to the three ideas the rest of the app assumes.
private struct IntroductionCard: View {
    var onDismiss: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("A sankalpa is a declared intent")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    point("1", "Declare it", "Commit to how many times, per day, week, month or year — and for how long.")
                    point("2", "Begin it", "Tracking starts. You can begin on an earlier date to cover sessions you have already done.")
                    point("3", "Log each session", "When a period closes it is judged: satisfied if you met the minimum, missed if you did not.")
                }

                Button("Got it", action: onDismiss)
                    .buttonStyle(.quiet)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func point(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(Palette.accent)
                .frame(width: 20, height: 20)
                .background(Palette.accent.opacity(0.14), in: .circle)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
