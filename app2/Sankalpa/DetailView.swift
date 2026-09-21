import SwiftUI
import SankalpaCore
import SankalpaStorage

struct DetailView: View {
    @Environment(PracticeModel.self) private var model
    let id: SankalpaId
    @State private var logging = false
    @State private var beginning = false
    @State private var finishing = false
    @State private var stopping = false
    var body: some View {
        Group {
            if let item = model.summary(id) { content(item) }
            else { ContentUnavailableView("Intention unavailable", systemImage: "leaf") }
        }.background(Ink.paper).navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Your practice")
            .toolbar {
                if let item = model.summary(id), model.latestEligibleMoment(item.sankalpa) != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Record a session", systemImage: "plus.circle") { logging = true }
                            .accessibilityIdentifier("record-at-time")
                    }
                }
            }
            .sheet(isPresented: $logging) { SessionForm(id: id) }
            .sheet(isPresented: $beginning) { BeginForm(id: id) }
            .confirmationDialog("How did this practice end?", isPresented: $finishing, titleVisibility: .visible) {
                Button("Completed successfully") { model.complete(id, outcome: .successfully) }
                Button("Completed unsuccessfully") { model.complete(id, outcome: .unsuccessfully) }
            } message: { Text("You decide the outcome. Completion is final. Only periods that closed before completion are evaluated; eligible past sessions can still be recorded.") }
            .confirmationDialog("Stop this practice?", isPresented: $stopping, titleVisibility: .visible) {
                Button("Stop practice", role: .destructive) { model.stop(id) }.accessibilityIdentifier("confirm-stop")
            } message: { Text("Stopping is final. The interrupted period will not be judged. Your history stays available.") }
    }
    private func content(_ item: SankalpaSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow(text: item.actionType.displayName)
                    Text(item.title).font(.largeTitle.weight(.medium)).fontDesign(.serif).fixedSize(horizontal: false, vertical: true)
                    Status(state: item.state)
                    if !item.sankalpa.description.isEmpty { Text(item.sankalpa.description.value).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
                Surface {
                    VStack(alignment: .leading, spacing: 18) {
                        if item.state == .inProgress, let progress = item.currentPeriod {
                            PracticeProgress(progress: progress)
                            Button { model.logNow(id) } label: { Label("Record session now", systemImage: "plus.circle") }.buttonStyle(FilledButton()).accessibilityIdentifier("record-now")
                        }
                        if item.state == .notStarted {
                            Text(item.commitment.startDate > model.today ? "This intention is waiting for its start date." : "Ready to begin? You can include a session you performed earlier today.").foregroundStyle(.secondary)
                            Button("Begin practice") { beginning = true }.buttonStyle(FilledButton())
                                .disabled(item.commitment.startDate > model.today).accessibilityIdentifier("begin-practice")
                        }
                        if item.state == .paused {
                            Button("Resume practice") { model.resume(id) }.buttonStyle(FilledButton()).accessibilityIdentifier("resume-practice")
                        }
                        if model.latestEligibleMoment(item.sankalpa) != nil {
                            Button("Log a past session", systemImage: "clock.arrow.circlepath") { logging = true }
                                .buttonStyle(OutlineButton()).accessibilityIdentifier("log-past")
                        }
                        if item.state == .paused { Text("Sessions performed before the pause can still be recorded. Pausing keeps your original schedule.").font(.footnote).foregroundStyle(.secondary) }
                        if item.state.isTerminal { Text("This practice is finished. You can still record sessions performed during its active time.").font(.footnote).foregroundStyle(.secondary) }
                        if item.state == .inProgress, item.currentPeriod == nil { Text("Your commitment has ended. Record any missing sessions, then decide how it went.").foregroundStyle(.secondary) }
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "The commitment")
                        Text(item.commitment.fullPhrase).font(.title3.weight(.medium))
                        info("Starts", item.commitment.startDate.longDisplayText)
                        info("Last day", item.commitment.endDate?.longDisplayText ?? "Ongoing")
                        info("Sessions recorded", "\(item.totalSessions)")
                        Text("The number of sessions is a minimum. Your periods begin on the start date.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Eyebrow(text: "Recent periods")
                        let outcomes = model.recentOutcomes(id).filter { $0.standing != .open }
                        if outcomes.isEmpty {
                            Text(item.state.isTerminal ? "No full periods closed before this practice ended." : "A period is evaluated once it closes.").foregroundStyle(.secondary)
                        } else {
                            Text("\(outcomes.filter { $0.standing == .satisfied }.count) of \(outcomes.filter { $0.standing != .paused }.count) evaluated periods satisfied")
                                .font(.headline)
                            Text("\(outcomes.first!.window.start.shortDisplayText) – \(outcomes.last!.window.end.shortDisplayText)")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(outcomes.suffix(3).reversed())) { outcome in OutcomeRow(outcome: outcome) }
                        }
                        NavigationLink(value: HistoryDestination(id: id, tab: .periods)) { Label("Explore period history", systemImage: "calendar") }
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Eyebrow(text: "Your record")
                        NavigationLink(value: HistoryDestination(id: id, tab: .sessions)) { Label("All sessions (\(item.totalSessions))", systemImage: "book.closed") }.accessibilityIdentifier("all-sessions")
                        Divider()
                        NavigationLink(value: HistoryDestination(id: id, tab: .changes)) { Label("Transition history", systemImage: "clock") }
                    }
                }
                if !item.state.isTerminal {
                    VStack(spacing: 12) {
                        if item.state == .inProgress { Button("Pause practice") { model.pause(id) }.buttonStyle(OutlineButton()).accessibilityIdentifier("pause-practice") }
                        Button("Complete practice…") { finishing = true }.buttonStyle(OutlineButton())
                        Button("Stop practice…", role: .destructive) { stopping = true }.padding(12).accessibilityIdentifier("stop-practice")
                    }
                }
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.navigationDestination(for: HistoryDestination.self) { destination in HistoryView(destination: destination) }
    }
    private func info(_ name: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text(name).foregroundStyle(.secondary); Spacer(minLength: 16); Text(value) }
            VStack(alignment: .leading, spacing: 4) { Text(name).foregroundStyle(.secondary); Text(value) }
        }.font(.subheadline).accessibilityElement(children: .ignore)
        .accessibilityLabel(name).accessibilityValue(value)
        .accessibilityIdentifier(name == "Sessions recorded" ? "session-total" : "value-\(name)")
    }
}
