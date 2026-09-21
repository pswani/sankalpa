import SwiftUI
import SankalpaCore
import SankalpaStorage

/// Required basics first, optional details after, with the derived commitment always visible so
/// "26 weeks" never has to be worked out in the user's head.
struct DeclareSankalpaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var actionType: ActionType = .meditation
    @State private var startDate = Date()
    @State private var periodUnit: PeriodUnit = .day
    @State private var timesPerPeriod = 1
    @State private var hasDuration = true
    @State private var periodCount = 30
    /// The duration field's own text, so it can be emptied and retyped.
    @State private var periodCountText = "30"
    @State private var error: SankalpaCommandError?

    @FocusState private var titleFocused: Bool
    @FocusState private var periodCountFocused: Bool

    /// No duration can be longer than `PeriodCount.maxValue`, so nothing past its digit count is
    /// worth keeping in the field.
    private var maxDurationDigits: Int { String(PeriodCount.maxValue).count }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The commitment as the domain would build it, used to preview the end date live.
    private var previewCommitment: Commitment? {
        guard let times = try? TimesPerPeriod(timesPerPeriod) else { return nil }
        let count = hasDuration ? try? PeriodCount(periodCount) : nil
        guard !hasDuration || count != nil else { return nil }
        return Commitment(
            startDate: AppTime.day(from: startDate),
            periodUnit: periodUnit,
            timesPerPeriod: times,
            periodCount: count
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                actionSection
                startSection
                scheduleSection
                durationSection
                summarySection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New sankalpa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Declare", action: declare)
                        .fontWeight(.semibold)
                        .disabled(trimmedTitle.isEmpty)
                }
                // The number pad has no return key, so it needs a way out that is not a guess.
                ToolbarItemGroup(placement: .keyboard) {
                    if periodCountFocused {
                        Spacer()
                        Button("Done") { periodCountFocused = false }
                    }
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section {
            // Labels stay visible once text is entered; a placeholder alone would disappear.
            labelledField("Title") {
                TextField("Morning Vipassana", text: $title)
                    .focused($titleFocused)
                    .submitLabel(.next)
                    .textInputAutocapitalization(.sentences)
            }
            labelledField("Description") {
                TextField("Optional — what this means to you", text: $description, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
            }
        } header: {
            Text("What you are committing to")
        } footer: {
            // The limit was only ever mentioned after tapping Declare, which is late to hear that
            // what you typed will not be accepted.
            if trimmedTitle.count > Title.maxLength {
                errorText(
                    DeclarationError.invalidTitle(.tooLong(max: Title.maxLength)).message
                        + " That is \(trimmedTitle.count) so far."
                )
            } else if case .declaration(.invalidTitle(let problem)) = error {
                errorText(DeclarationError.invalidTitle(problem).message)
            }
        }
    }

    private func labelledField(
        _ label: String, @ViewBuilder field: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            field()
        }
        .padding(.vertical, 2)
    }

    private var startSection: some View {
        Section {
            DatePicker(
                "Start date",
                selection: $startDate,
                in: earliestStart...latestStart,
                displayedComponents: .date
            )
        } header: {
            Text("When it starts")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("A sankalpa can start up to a year in the past, or on a date still to come — it simply waits until you begin it.")
                if case .declaration(.startDateTooFarInPast(let earliest)) = error {
                    errorText(DeclarationError.startDateTooFarInPast(earliestAllowed: earliest).message)
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Picker("Action type", selection: $actionType) {
                ForEach(ActionType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.symbolName).tag(type)
                }
            }
        } header: {
            Text("Action type")
        } footer: {
            Text("For example: \(actionType.exampleHint).")
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker("Period", selection: $periodUnit) {
                ForEach(PeriodUnit.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $timesPerPeriod, in: 1...TimesPerPeriod.maxValue) {
                HStack {
                    Text("Number of times")
                    Spacer()
                    Text("\(timesPerPeriod)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("How often")
        } footer: {
            Text("This is a minimum. Acting more often than committed still satisfies the period.")
        }
    }

    private var durationSection: some View {
        Section {
            Toggle("Set a duration", isOn: $hasDuration.animation(.snappy))

            if hasDuration {
                // A stepper alone means 150 taps to get from 30 days to 180, so the number is
                // typed and the stepper is there for the small adjustments it is good at.
                HStack(spacing: 12) {
                    Text("Number of \(periodUnit.pluralName(2))")
                    Spacer(minLength: 8)
                    // Bound to text rather than to the number directly: a numeric binding
                    // rewrites the field on every keystroke, so it can never be emptied and
                    // retyped — which is the whole point of typing it.
                    TextField(String(periodCount), text: $periodCountText)
                        .focused($periodCountFocused)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 72)
                        .accessibilityLabel("Number of \(periodUnit.pluralName(2))")

                    Stepper(value: $periodCount, in: 1...PeriodCount.maxValue) {
                        EmptyView()
                    }
                    .labelsHidden()
                }
                .onChange(of: periodCountText) { _, text in
                    // Plain ASCII digits only. `isNumber` also admits things like "½", which
                    // the number pad cannot produce but a paste can.
                    let digits = String(
                        text.filter { $0.isASCII && $0.isNumber }.prefix(maxDurationDigits)
                    )
                    if digits != text { periodCountText = digits }
                    // An empty field mid-edit is not a duration of zero; the form keeps the last
                    // real value until another one is typed.
                    if let typed = Int(digits), typed >= 1 {
                        periodCount = min(typed, PeriodCount.maxValue)
                    }
                }
                .onChange(of: periodCount) { _, value in
                    if Int(periodCountText) != value { periodCountText = String(value) }
                }
                .onChange(of: periodCountFocused) { _, focused in
                    // Tapping in starts a fresh number. A three-digit duration is quicker to
                    // retype than to edit, and putting the caret somewhere the user did not
                    // choose is how 30 becomes 1803. The current value stays on as the
                    // placeholder, and comes back if nothing is typed.
                    periodCountText = focused ? "" : String(periodCount)
                }
            }
        } header: {
            Text("Duration")
        } footer: {
            Text(
                hasDuration
                    ? "A duration is a whole number of periods, up to \(PeriodCount.maxValue). Six months of a weekly commitment is 26 weeks."
                    : "Without a duration, the sankalpa is tracked until you stop it."
            )
        }
    }

    private var summarySection: some View {
        Section {
            if let commitment = previewCommitment {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ActionChip(actionType: actionType, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trimmedTitle.isEmpty ? "Untitled sankalpa" : trimmedTitle)
                                .font(.headline)
                                .foregroundStyle(trimmedTitle.isEmpty ? .secondary : .primary)
                            Text(commitment.fullPhrase)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    LabeledContent("Starts", value: commitment.startDate.longDisplayText)
                        .font(.footnote)
                    LabeledContent(
                        "Ends",
                        value: commitment.endDate?.longDisplayText ?? "When you stop it"
                    )
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Summary")
        } footer: {
            switch error {
            case .declaration(.invalidTitle), .declaration(.startDateTooFarInPast):
                EmptyView()
            case .some(let error):
                errorText(error.message)
            case .none:
                // Never disable Declare without saying what is missing.
                if trimmedTitle.isEmpty {
                    Text("Add a title to declare this sankalpa.")
                }
            }
        }
    }

    private func errorText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Palette.missed)
    }

    // MARK: - Dates

    /// S3 — a sankalpa may start at most one year in the past. A future start is allowed; it simply
    /// waits in Not started.
    private var earliestStart: Date {
        AppTime.date(from: model.today.addingYears(-1))
    }

    private var latestStart: Date {
        AppTime.date(from: model.today.addingYears(1))
    }

    private func declare() {
        let declaration = Declaration(
            title: title,
            description: description,
            actionType: actionType,
            startDate: AppTime.day(from: startDate),
            periodUnit: periodUnit,
            timesPerPeriod: timesPerPeriod,
            periodCount: hasDuration ? periodCount : nil
        )
        withAnimation(.snappy) { error = model.declare(declaration) }
        if error == nil { dismiss() }
    }
}
