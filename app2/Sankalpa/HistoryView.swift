import SwiftUI
import SankalpaCore
import SankalpaStorage

enum HistoryTab: String, CaseIterable { case periods = "Periods", sessions = "Sessions", changes = "Changes" }
struct HistoryDestination: Hashable {
    let id: SankalpaId
    let tab: HistoryTab
}
struct HistoryView: View {
    @Environment(PracticeModel.self) private var model
    let destination: HistoryDestination
    @State private var tab: HistoryTab
    @State private var page = 0
    @State private var selectedDate = Date()
    init(destination: HistoryDestination) { self.destination = destination; _tab = State(initialValue: destination.tab) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("History", selection: $tab) { ForEach(HistoryTab.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
                if let item = model.summary(destination.id) {
                    switch tab {
                    case .periods: periods(item)
                    case .sessions: sessions(item)
                    case .changes: changes(item)
                    }
                }
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Ink.paper).navigationTitle("Practice history").navigationBarTitleDisplayMode(.inline)
    }
    private func periods(_ item: SankalpaSummary) -> some View {
        let c = item.commitment
        let lastDay = min(model.today, c.endDate ?? model.today, item.sankalpa.lifecycle.terminalTransition?.effectiveAt.day.addingDays(-1) ?? model.today)
        let latest = c.windowContaining(lastDay)?.index ?? 0
        let endIndex = max(0, latest - page * 30)
        let firstIndex = max(0, endIndex - 29)
        let from = c.window(at: firstIndex)!.start
        let until = c.window(at: endIndex)!.start
        let outcomes = c.startDate > model.today ? [] : model.outcomes(item.id, from: from, until: until)
        let tally = PeriodTally(outcomes: outcomes)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Older", systemImage: "chevron.left") { page += 1 }.disabled(firstIndex == 0).frame(minHeight: 44)
                Spacer()
                Button("Newer", systemImage: "chevron.right") { page = max(0, page - 1) }.disabled(page == 0).frame(minHeight: 44)
            }
            if outcomes.isEmpty {
                EmptyPractice(title: "No evaluated periods", message: item.state.isTerminal ? "No full periods closed before this practice ended." : "Your periods will appear here as the commitment begins.", symbol: "calendar")
            } else {
                Surface {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(outcomes.first!.window.start.shortDisplayText) – \(outcomes.last!.window.end.shortDisplayText)").font(.headline)
                        Text("\(tally.satisfied) satisfied · \(tally.unsatisfied) missed · \(tally.paused) paused").font(.subheadline).foregroundStyle(.secondary)
                        Text("Counts cover only the periods shown below.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(outcomes.reversed()) { outcome in Surface { OutcomeRow(outcome: outcome) } }
            }
        }
    }
    private func sessions(_ item: SankalpaSummary) -> some View {
        let day = AppTime.day(from: selectedDate)
        let month = CalendarDay(year: day.year, month: day.month, day: 1)!
        let entries = model.sessions(item.id, from: month, until: month.addingMonths(1).addingDays(-1))
        return VStack(spacing: 16) {
            DatePicker("Month containing", selection: $selectedDate, in: AppTime.date(from: min(item.commitment.startDate, model.today).monthStart)...AppTime.date(from: .endOfDay(model.today)), displayedComponents: .date)
            MonthPicker(month: Binding(get: { month }, set: { selectedDate = AppTime.date(from: $0) }), oldest: item.commitment.startDate, today: model.today)
            if entries.isEmpty { EmptyPractice(title: "No sessions this month", message: "Choose another month to explore older practice.", symbol: "book.closed") }
            ForEach(entries) { entry in Surface { SessionLine(session: entry, today: model.today) } }
        }
    }
    private func changes(_ item: SankalpaSummary) -> some View {
        let transitions = model.history(item.id)
        return VStack(spacing: 14) {
            if transitions.isEmpty { EmptyPractice(title: "A fresh intention", message: "Your lifecycle history starts when you begin, complete, or stop this practice.", symbol: "clock") }
            ForEach(Array(transitions.enumerated()), id: \.offset) { _, transition in
                Surface {
                    VStack(alignment: .leading, spacing: 10) {
                        Status(state: transition.to)
                        Text("From \(transition.from.displayName.lowercased())").font(.subheadline).foregroundStyle(.secondary)
                        Text("Effective: \(transition.effectiveAt.day.shortDisplayText), \(AppTime.timeText(transition.effectiveAt))").font(.footnote)
                        Text("Recorded: \(transition.recordedAt.day.shortDisplayText), \(AppTime.timeText(transition.recordedAt))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
struct OutcomeRow: View {
    let outcome: PeriodOutcome
    private var icon: String {
        switch outcome.standing { case .open: "circle.dotted"; case .paused: "pause.circle"; case .satisfied: "checkmark.circle.fill"; case .unsatisfied: "minus.circle" }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(outcome.standing == .unsatisfied ? Ink.warm : Ink.accent).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(outcome.window.displayText).font(.subheadline.weight(.medium))
                Text(outcome.standing == .paused ? "Paused throughout · no sessions required" : "\(outcome.performed) recorded · \(outcome.required) minimum").font(.caption).foregroundStyle(.secondary)
                Text(outcome.standing == .unsatisfied ? "Missed \(outcome.missed)" : outcome.standing.displayName).font(.caption.weight(.semibold)).foregroundStyle(Ink.accent)
            }
        }.accessibilityElement(children: .combine)
    }
}
struct SessionLine: View {
    let session: Session
    let today: CalendarDay
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle").foregroundStyle(Ink.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(AppTime.dayText(session.occurredAt.day, today: today)).font(.subheadline.weight(.semibold))
                Text("Performed at \(AppTime.timeText(session.occurredAt))").font(.subheadline).foregroundStyle(.secondary)
                if session.wasBackdated { Text("Recorded \(session.loggedAt.day.shortDisplayText)").font(.caption).foregroundStyle(.secondary) }
            }
        }.accessibilityElement(children: .combine)
    }
}
struct JournalView: View {
    @Environment(PracticeModel.self) private var model
    @State private var date = Date()
    @State private var search = ""
    private var month: CalendarDay { let day = AppTime.day(from: date); return CalendarDay(year: day.year, month: day.month, day: 1)! }
    private var entries: [JournalEntry] {
        model.journal(from: month, until: month.addingMonths(1).addingDays(-1)).filter { search.isEmpty || $0.sankalpaTitle.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("The moments you made time for.").font(.title2).fontDesign(.serif)
                    DatePicker("Month containing", selection: $date, in: AppTime.date(from: model.oldestDay.monthStart)...AppTime.date(from: .endOfDay(model.today)), displayedComponents: .date)
                    MonthPicker(month: Binding(get: { month }, set: { date = AppTime.date(from: $0) }), oldest: model.oldestDay, today: model.today)
                    Text("\(entries.count) sessions\(search.isEmpty ? "" : " matching your search") this month").font(.subheadline).foregroundStyle(.secondary)
                    if entries.isEmpty { EmptyPractice(title: "A page waiting to be written", message: "Recorded sessions appear here. You can explore any month in your practice history.", symbol: "book.closed") }
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.session.sankalpaId) {
                            Surface {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(entry.sankalpaTitle).font(.headline).foregroundStyle(.primary)
                                    SessionLine(session: entry.session, today: model.today).foregroundStyle(.primary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(Ink.paper).navigationTitle("Journal")
                .searchable(text: $search, prompt: "Find a practice in this month")
                .navigationDestination(for: SankalpaId.self) { DetailView(id: $0) }
        }
    }
}
