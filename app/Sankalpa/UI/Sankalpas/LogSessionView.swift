import SwiftUI
import SankalpaCore
import SankalpaStorage

/// Logging a session for a moment other than right now. The rules that can refuse it are stated up
/// front, and the picker is bounded so most refusals never arise.
struct LogSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let summary: SankalpaSummary
    @State private var occurredAt = Date()
    @State private var error: SankalpaCommandError?

    private var commitment: Commitment { summary.commitment }

    /// The newest moment the domain would still accept. After a pause or a stop this is before
    /// that transition, not now — so the picker cannot offer a time that would be refused.
    private var latestEligible: CalendarMoment? {
        model.latestEligibleMoment(for: summary.sankalpa)
    }

    /// The picker never offers a moment before the start date, after the commitment, or outside an
    /// In progress stretch.
    private var range: ClosedRange<Date> {
        let lower = AppTime.date(from: CalendarMoment.startOfDay(commitment.startDate))
        let upper = AppTime.date(from: latestEligible ?? model.now())
        return lower...max(lower, upper)
    }

    private var footerText: String {
        let base = "A session records something you have already done, so it cannot be in the future."
        guard summary.state != .inProgress, latestEligible != nil else { return base }
        // Paused and finished sankalpas can still be backfilled, but only inside a stretch when
        // they were actually running — say so rather than letting the domain refuse it later.
        return base + " It must also fall inside a time when this sankalpa was In progress."
    }

    /// What this session would do to the period it lands in.
    private var landingPeriod: (window: PeriodWindow, performed: Int, required: Int)? {
        guard let window = commitment.windowContaining(AppTime.day(from: occurredAt)) else {
            return nil
        }
        return (
            window,
            model.performedCount(summary.id, in: window),
            commitment.timesPerPeriod.value
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Performed at",
                        selection: $occurredAt,
                        in: range,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } header: {
                    Text("When you performed it")
                } footer: {
                    Text(footerText)
                }

                if let landing = landingPeriod {
                    Section("This would count toward") {
                        LabeledContent(
                            landing.window.unitNoun.capitalizedFirst,
                            value: landing.window.displayText
                        )
                        LabeledContent(
                            "After logging",
                            value: "\(landing.performed + 1) of \(landing.required)"
                        )
                    }
                }

                if let error {
                    Section {
                        Label(error.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Palette.missed)
                    }
                }
            }
            .navigationTitle("Log a session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log", action: log).fontWeight(.semibold)
                }
            }
            // Opens at the newest eligible moment rather than now, so a paused or finished
            // sankalpa starts on a time that will actually be accepted.
            .onAppear { occurredAt = range.upperBound }
        }
        .presentationDetents([.medium, .large])
    }

    private func log() {
        withAnimation(.snappy) {
            error = model.logSession(summary.id, occurredAt: AppTime.moment(from: occurredAt))
        }
        if error == nil { dismiss() }
    }
}

/// Begin, optionally effective on an earlier date, so sessions already performed can be logged.
struct BeginSankalpaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let summary: SankalpaSummary
    @State private var effectiveAt = Date()

    private var range: ClosedRange<Date> {
        let lower = AppTime.date(from: CalendarMoment.startOfDay(summary.commitment.startDate))
        let upper = AppTime.date(from: model.now())
        return lower...max(lower, upper)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "In progress from",
                        selection: $effectiveAt,
                        in: range,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } footer: {
                    Text("Beginning is the one change that can be backdated, so you can record sessions you have already performed. It cannot be earlier than the start date, \(summary.commitment.startDate.longDisplayText), or in the future. Every later change takes effect when you make it.")
                }
            }
            .navigationTitle("Begin sankalpa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Begin") {
                        model.begin(summary.id, effectiveAt: AppTime.moment(from: effectiveAt))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { effectiveAt = range.lowerBound }
        }
        .presentationDetents([.medium])
    }
}
