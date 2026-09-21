import SwiftUI
import SankalpaCore
import SankalpaStorage

struct DeclarationView: View {
    @Environment(PracticeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var action = ActionType.meditation
    @State private var start = Date()
    @State private var unit = PeriodUnit.day
    @State private var count = "1"
    @State private var finite = false
    @State private var duration = "30"
    @State private var error: String?
    private var preview: Commitment? {
        guard let n = Int(count), let times = try? TimesPerPeriod(n) else { return nil }
        let periods = finite ? Int(duration).flatMap { try? PeriodCount($0) } : nil
        guard !finite || periods != nil else { return nil }
        return Commitment(startDate: AppTime.day(from: start), periodUnit: unit, timesPerPeriod: times, periodCount: periods)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("What will you return to?").font(.title2).fontDesign(.serif).listRowBackground(Color.clear)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Title").font(.caption).foregroundStyle(.secondary)
                        TextField("Morning meditation", text: $title).accessibilityIdentifier("intention-title")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Why it matters (optional)").font(.caption).foregroundStyle(.secondary)
                        TextField("A few words for yourself", text: $note, axis: .vertical).lineLimit(2...5)
                    }
                    Picker("Practice", selection: $action) { ForEach(ActionType.allCases, id: \.self) { Text($0.displayName) } }
                } footer: { Text("A sankalpa is an intention with a commitment to act.") }
                Section("Your rhythm") {
                    Picker("Period", selection: $unit) { ForEach(PeriodUnit.allCases, id: \.self) { Text($0.displayName) } }
                    numericField("Sessions per \(unit.displayName.lowercased())", text: $count, id: "session-count")
                    DatePicker("Start date", selection: $start, in: AppTime.date(from: model.today.addingYears(-1))..., displayedComponents: .date)
                }
                Section {
                    Toggle("Set a duration", isOn: $finite)
                    if finite { numericField("Number of \(unit.pluralName(2))", text: $duration, id: "period-count") }
                } footer: { Text(finite ? "Use whole periods. For example, 26 weeks for a weekly commitment of about six months." : "An ongoing intention continues until you choose to finish or stop.") }
                if let commitment = preview {
                    Section("Your commitment") {
                        Text(commitment.fullPhrase).font(.headline)
                        Text("Starts \(commitment.startDate.longDisplayText)").font(.subheadline)
                        if let end = commitment.endDate { Text("Last day: \(end.longDisplayText)").font(.subheadline) }
                        Text("You’ll begin the practice separately, when you are ready.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Ink.danger).accessibilityIdentifier("form-error") } }
            }
            .scrollContentBackground(.hidden).background(Ink.paper).scrollDismissesKeyboard(.interactively)
            .navigationTitle("New intention").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Declare") { save() }.fontWeight(.semibold).accessibilityIdentifier("save-intention") }
            }
        }
    }
    private func numericField(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            TextField(label, text: text).keyboardType(.numberPad).accessibilityIdentifier(id)
        }.padding(.vertical, 3)
    }
    private func save() {
        guard let n = Int(count), (1...TimesPerPeriod.maxValue).contains(n) else { error = "Enter 1–99 sessions per period."; return }
        let periods = finite ? Int(duration) : nil
        guard !finite || (periods != nil && (1...PeriodCount.maxValue).contains(periods!)) else { error = "Enter 1–3,650 whole periods."; return }
        if model.declare(Declaration(title: title, description: note, actionType: action, startDate: AppTime.day(from: start), periodUnit: unit, timesPerPeriod: n, periodCount: periods)) != nil { dismiss() }
        else { error = model.alert; model.alert = nil }
    }
}
struct SessionForm: View {
    @Environment(PracticeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: SankalpaId
    @State private var time = Date()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            if let summary = model.summary(id) {
                Form {
                    Section {
                        Text(summary.title).font(.title2).fontDesign(.serif)
                        DatePicker("Performed at", selection: $time, in: range(summary), displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("performed-at")
                    } footer: { Text("Choose when you actually performed the session. It must fall within an In progress interval, even if this practice is now paused or finished.") }
                    if let window = summary.commitment.windowContaining(AppTime.day(from: time)) {
                        Section("This session belongs to") {
                            Text(window.displayText).font(.headline)
                            Text("\(model.performed(id, in: window) + 1) recorded · \(summary.commitment.timesPerPeriod.value) minimum").foregroundStyle(.secondary)
                        }
                    }
                    if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Ink.danger).accessibilityIdentifier("session-error") } }
                }.scrollContentBackground(.hidden).background(Ink.paper)
                    .onAppear {
                        if let latest = model.latestEligibleMoment(summary.sankalpa) { time = AppTime.date(from: latest) }
                    }
                    .navigationTitle("Past session").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Record") {
                                error = model.log(id, at: AppTime.moment(from: time))
                                if error == nil { dismiss() }
                            }.fontWeight(.semibold).accessibilityIdentifier("save-session")
                        }
                    }
            }
        }
    }
    private func range(_ summary: SankalpaSummary) -> ClosedRange<Date> {
        let lower = AppTime.date(from: summary.commitment.startDate)
        var upper = AppTime.date(from: model.now())
        if let end = summary.commitment.endDate { upper = min(upper, AppTime.date(from: .endOfDay(end))) }
        return lower...max(lower, upper)
    }
}
struct BeginForm: View {
    @Environment(PracticeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: SankalpaId
    @State private var time = Date()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            if let summary = model.summary(id) {
                Form {
                    Section {
                        Text("When did your practice begin?").font(.title2).fontDesign(.serif)
                        DatePicker("In progress from", selection: $time, in: AppTime.date(from: summary.commitment.startDate)...max(AppTime.date(from: summary.commitment.startDate), AppTime.date(from: model.now())), displayedComponents: [.date, .hourAndMinute])
                        Button("From the start of today") { time = AppTime.date(from: max(summary.commitment.startDate, model.today)) }.accessibilityIdentifier("begin-today-start")
                    } footer: { Text("Begin now, earlier today, or on a past date within this commitment. This is the only lifecycle change that can be backdated.") }
                    if let error { Section { Text(error).foregroundStyle(Ink.danger) } }
                }.scrollContentBackground(.hidden).background(Ink.paper)
                    .navigationTitle("Begin practice").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Begin") {
                                if model.begin(id, at: AppTime.moment(from: time)) { dismiss() }
                                else { error = model.alert; model.alert = nil }
                            }.accessibilityIdentifier("confirm-begin")
                        }
                    }
                    .onAppear { time = AppTime.date(from: model.now()) }
            }
        }
    }
}
