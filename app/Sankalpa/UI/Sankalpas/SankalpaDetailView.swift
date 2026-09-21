import SwiftUI
import SankalpaCore
import SankalpaStorage

struct SankalpaDetailView: View {
    @Environment(AppModel.self) private var model
    let sankalpaId: SankalpaId

    @State private var loggingSession = false
    @State private var beginningWithDate = false
    @State private var confirmingComplete = false
    @State private var confirmingStop = false

    @Environment(\.dynamicTypeSize) private var typeSize

    private var summary: SankalpaSummary? { model.summary(sankalpaId) }

    var body: some View {
        Group {
            if let summary {
                content(summary)
            } else {
                ContentUnavailableView(
                    "Sankalpa unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("This sankalpa is no longer in the app.")
                )
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(summary?.title ?? "Sankalpa")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Recording a forgotten session stays reachable from every state that ever had
            // eligible time — including Paused and the terminal ones. The domain already allows a
            // session dated inside an earlier In progress stretch; until now no screen offered it.
            if let summary, summary.sankalpa.lifecycle.beganAt != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log a past session", systemImage: "clock.arrow.circlepath") {
                        loggingSession = true
                    }
                }
            }
        }
        .sheet(isPresented: $loggingSession) {
            if let summary { LogSessionView(summary: summary) }
        }
        .sheet(isPresented: $beginningWithDate) {
            if let summary { BeginSankalpaView(summary: summary) }
        }
    }

    private func content(_ summary: SankalpaSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard(summary)

                if summary.state == .inProgress, let period = summary.currentPeriod {
                    currentPeriodCard(summary, period)
                }

                commitmentCard(summary)
                periodsSection(summary)
                sessionsSection(summary)
                lifecycleSection(summary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Header

    private func headerCard(_ summary: SankalpaSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                // Three things abreast is fine at standard sizes and unreadable at accessibility
                // ones, where the title wraps to a sliver and the badge breaks mid-word.
                let headerLayout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 12))

                headerLayout {
                    ActionChip(actionType: summary.actionType, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summary.actionType.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    StateBadge(state: summary.state)
                }

                if !summary.sankalpa.description.isEmpty {
                    Text(summary.sankalpa.description.value)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                Text(summary.state.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Current period

    private func currentPeriodCard(
        _ summary: SankalpaSummary, _ period: CurrentPeriodProgress
    ) -> some View {
        // This is what the user opened the screen for, so it is the one card that is allowed to
        // look different from the rest.
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    PeriodProgressRing(
                        performed: period.performed, required: period.required,
                        tint: summary.actionType.tint,
                        baseDiameter: 80, lineWidth: 8
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(period.window.unit.currentPeriodTitle.uppercased())
                            .font(.caption.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Text(period.sessionCountPhrase)
                            .font(.title2.weight(.semibold))
                        // A daily window's dates are already in the heading, so only show the
                        // span when it actually spans something.
                        if period.window.dayCount > 1 {
                            Text(period.window.displayText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if period.isSatisfied {
                    Label(
                        "Satisfied. Anything more still counts as performed.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(Palette.satisfied)
                } else {
                    Text("\(period.remaining) more to satisfy this period.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        _ = model.logSession(summary.id, occurredAt: model.now())
                    } label: {
                        Label(
                            period.isSatisfied ? "Log another" : "Log a session",
                            systemImage: "checkmark.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(period.isSatisfied ? AnyButtonStyle(.quiet) : AnyButtonStyle(.primary))

                    Button { loggingSession = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Log a session at another time")
                }
            }
        }
    }

    // MARK: - Commitment

    private func commitmentCard(_ summary: SankalpaSummary) -> some View {
        let commitment = summary.commitment
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Commitment")
            Card {
                VStack(spacing: 0) {
                    detailRow("How often", commitment.frequencyPhrase)
                    Divider().background(Palette.hairline)
                    detailRow("Duration", commitment.durationValueText)
                    Divider().background(Palette.hairline)
                    detailRow("Starts", commitment.startDate.longDisplayText)
                    Divider().background(Palette.hairline)
                    detailRow(
                        "Ends",
                        commitment.endDate?.longDisplayText ?? "When you stop it",
                        footnote: commitment.endDate == nil
                            ? nil
                            : "Inclusive. Reaching it does not change the state by itself."
                    )
                    if summary.totalSessions > 0 {
                        Divider().background(Palette.hairline)
                        detailRow("Sessions logged", "\(summary.totalSessions)")
                    }
                }
            }

            // Better to say this than to leave the user hunting for an Edit button that is not
            // there.
            Text("A declared sankalpa cannot be edited. If the commitment itself needs to change, stop this one and declare another.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func detailRow(_ label: String, _ value: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.trailing)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Periods

    private func periodsSection(_ summary: SankalpaSummary) -> some View {
        let outcomes = model.recentPeriodOutcomes(summary.id)
        let tally = model.periodTally(summary.id)

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Periods")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    // Until at least one period has closed there is nothing to count, and a row of
                    // zeroes next to a single open window says less than one sentence does.
                    if tally.isEmpty {
                        Text(periodsEmptyText(summary))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        TallyRow(tally: tally)

                        if !outcomes.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(outcomes) { outcome in
                                        StandingTile(outcome: outcome)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .defaultScrollAnchor(.trailing)

                            NavigationLink {
                                PeriodHistoryView(summary: summary)
                            } label: {
                                Label("Every period", systemImage: "square.grid.2x2")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func periodsEmptyText(_ summary: SankalpaSummary) -> String {
        let commitment = summary.commitment
        if commitment.startDate > model.today {
            return "Tracking begins on \(commitment.startDate.longDisplayText). Each period is judged once it closes."
        }
        if summary.state == .notStarted {
            return "Begin the sankalpa to start tracking. Each period is judged once it closes."
        }
        return "The first \(commitment.periodUnit.displayName.lowercased()) has not closed yet."
    }

    // MARK: - Sessions

    private func sessionsSection(_ summary: SankalpaSummary) -> some View {
        let sessions = Array(model.recentSessions(summary.id).prefix(5))

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Recent sessions")
            Card {
                if sessions.isEmpty {
                    Text("No sessions logged yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { Divider().background(Palette.hairline) }
                            SessionRow(session: session, today: model.today)
                        }
                        Divider().background(Palette.hairline)
                        NavigationLink {
                            SessionHistoryView(summary: summary)
                        } label: {
                            Label("All sessions", systemImage: "list.bullet")
                                .font(.subheadline)
                                .padding(.top, 12)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle

    private func lifecycleSection(_ summary: SankalpaSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Lifecycle")
            Card {
                VStack(spacing: 10) {
                    lifecycleActions(summary)

                    Divider().background(Palette.hairline)

                    NavigationLink {
                        LifecycleHistoryView(summary: summary)
                    } label: {
                        Label("Transition history", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// A lifecycle action. The width comes from the label, not the button, so the capsule actually
    /// fills the row instead of hugging its text and floating in the middle.
    private func lifecycleButton(
        _ title: String,
        style: AnyButtonStyle,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(style)
    }

    @ViewBuilder
    private func lifecycleActions(_ summary: SankalpaSummary) -> some View {
        let state = summary.state

        if state.isTerminal {
            Label(
                "This sankalpa is finished. \(state.displayName) is a final state.",
                systemImage: state.symbolName
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 10) {
                if state == .notStarted {
                    lifecycleButton("Begin now", style: .primary) { model.begin(summary.id) }
                        .disabled(summary.commitment.startDate > model.today)

                    // Enabled on the start date itself: declaring at noon and beginning at 07:00
                    // the same morning is exactly how a session already performed gets recorded.
                    lifecycleButton("Begin at an earlier time…", style: .quiet) {
                        beginningWithDate = true
                    }
                    .disabled(summary.commitment.startDate > model.today)
                }

                if state == .inProgress {
                    lifecycleButton("Pause", style: .quiet) { model.pause(summary.id) }
                }

                if state == .paused {
                    lifecycleButton("Resume", style: .primary) { model.resume(summary.id) }
                }

                // Ending a sankalpa is a different kind of act from pausing it, so it is set apart
                // and Stop is coloured as the irreversible thing it is.
                Divider().background(Palette.hairline).padding(.vertical, 2)

                HStack(spacing: 10) {
                    lifecycleButton("Complete…", style: .quiet) { confirmingComplete = true }
                    lifecycleButton("Stop…", style: .quiet(tint: Palette.missed)) {
                        confirmingStop = true
                    }
                }
            }
            .confirmationDialog(
                "How did this sankalpa end?",
                isPresented: $confirmingComplete,
                titleVisibility: .visible
            ) {
                Button("Completed successfully") {
                    model.complete(summary.id, outcome: .successfully)
                }
                Button("Completed unsuccessfully") {
                    model.complete(summary.id, outcome: .unsuccessfully)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You decide the outcome. Completing is final, and only periods that closed before now are judged.")
            }
            .confirmationDialog(
                "Stop this sankalpa?",
                isPresented: $confirmingStop,
                titleVisibility: .visible
            ) {
                Button("Stop", role: .destructive) { model.stop(summary.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stopping is final. The period you are in now and every period after it are left unjudged.")
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let today: CalendarDay
    /// False when the row sits under a section header that already names the day.
    var showsDate: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.satisfied)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 1) {
                if showsDate {
                    Text(AppTime.relativeDayText(session.occurredAt.day, today: today))
                        .font(.subheadline.weight(.medium))
                    Text(AppTime.timeText(session.occurredAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(AppTime.timeText(session.occurredAt))
                        .font(.subheadline.weight(.medium))
                }
            }

            Spacer(minLength: 0)

            if session.wasBackdated {
                Text("Backdated")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
