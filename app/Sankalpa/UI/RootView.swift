import SwiftUI
import SankalpaCore
import SankalpaStorage

/// Named `AppTab` because SwiftUI's own `Tab` is the view used below.
enum AppTab: Hashable {
    case today, sankalpas, journal
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab: AppTab = .today
    @State private var declaringSankalpa = false
    @State private var listFilter: SankalpaListView.Filter = .active
    @State private var showingPendingChanges = false

    var body: some View {
        @Bindable var model = model

        Group {
            // A service that has never answered takes over the whole app. Showing an empty
            // practice instead would be indistinguishable from a first run, and inviting the user
            // to declare into a service that is not listening would lose what they typed.
            if let problem = model.connectionProblem {
                RecoveryView(message: problem)
            } else {
                tabs
            }
        }
        .sheet(isPresented: $declaringSankalpa) {
            DeclareSankalpaView()
        }
        .sheet(isPresented: $showingPendingChanges) {
            NavigationStack { PendingChangesView() }
        }
        .alert(
            model.alertTitle,
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.dismissAlert() } }
            ),
            presenting: model.alertMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .safeAreaInset(edge: .top) {
            // Saying the practice may be behind matters more than it looks: without it, a session
            // logged offline and a session the service has taken are indistinguishable, and the
            // user has no way to know whether their practice is actually recorded anywhere but
            // this phone.
            if model.isShowingCachedPractice || model.pendingSessionCount > 0
                || model.reliabilityProblem != nil {
                OfflineNotice(
                    isCached: model.isShowingCachedPractice,
                    pendingCount: model.pendingSessionCount,
                    hasRecoveryProblem: model.reliabilityProblem != nil,
                    open: { showingPendingChanges = true }
                )
            }
        }
        .overlay(alignment: .top) {
            if let confirmation = model.confirmation {
                ConfirmationBanner(
                    text: confirmation,
                    showsUndo: model.undoReceipt != nil,
                    undo: { model.undoLastSession() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: model.confirmationToken) {
                    // Long enough to notice, short enough not to linger.
                    // A newer confirmation cancels this task. Returning on cancellation is
                    // essential: the old timer must never clear a newer banner (and its Undo).
                    do { try await Task.sleep(for: .seconds(4)) }
                    catch { return }
                    withAnimation(.snappy) { model.clearConfirmation() }
                }
            }
        }
        .animation(.snappy, value: model.confirmation)
        .sensoryFeedback(.success, trigger: model.successCount)
        .task(id: model.pendingSessionCount) {
            // Foreground/launch refreshes remain the primary trigger. While the app stays open,
            // this bounded cadence also lets a pending deletion finish when connectivity returns.
            while model.pendingSessionCount > 0 {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                await model.refresh()
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Today", systemImage: "sun.horizon", value: AppTab.today) {
                TodayView(
                    onDeclare: { declaringSankalpa = true },
                    onShowFinished: {
                        listFilter = .finished
                        selectedTab = .sankalpas
                    }
                )
            }
            Tab("Sankalpas", systemImage: "list.bullet.rectangle", value: AppTab.sankalpas) {
                SankalpaListView(
                    onDeclare: { declaringSankalpa = true },
                    filter: $listFilter
                )
            }
            Tab("Journal", systemImage: "book.closed", value: AppTab.journal) {
                JournalView()
            }
        }
        .alert(
            "Log another session?",
            isPresented: Binding(
                get: { model.repeatLogProposal != nil },
                set: { if !$0 && model.repeatLogProposal != nil { model.resolveRepeatLog(confirmed: false) } }
            ),
            presenting: model.repeatLogProposal
        ) { _ in
            Button("Cancel", role: .cancel) { model.resolveRepeatLog(confirmed: false) }
            Button("Log another") { model.resolveRepeatLog(confirmed: true) }
        } message: { proposal in
            Text("A session for \(proposal.sankalpaTitle) was just logged. Confirm to record a separate session.")
        }
    }
}

/// Says that what is on screen came from this phone rather than from the service just now, and
/// how much is still waiting to reach it.
///
/// It is a strip rather than an alert because this is a state, not an event: it lasts as long as
/// the service is away, and an alert that kept coming back would be worse than useless.
private struct OfflineNotice: View {
    let isCached: Bool
    let pendingCount: Int
    let hasRecoveryProblem: Bool
    let open: () -> Void

    private var text: String {
        if hasRecoveryProblem {
            return "Preserved session changes need attention"
        }
        switch (isCached, pendingCount) {
        case (_, let waiting) where waiting > 0 && isCached:
            return "Showing this phone's copy · \(waiting) session change\(waiting == 1 ? "" : "s") pending"
        case (false, let waiting) where waiting > 0:
            return "\(waiting) session change\(waiting == 1 ? "" : "s") pending"
        default:
            return "Showing this phone's copy — the service could not be reached"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: hasRecoveryProblem
                      ? "exclamationmark.triangle" : "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                    .accessibilityHidden(true)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .font(.footnote.weight(.medium))
        .foregroundStyle(Palette.pausedTint)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

private struct PendingChangesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    var body: some View {
        List {
            if let problem = model.reliabilityProblem {
                Section {
                    Text(problem)
                    Button("Discard preserved changes…", role: .destructive) {
                        confirmingDiscard = true
                    }
                } header: {
                    Text("Recovery required")
                } footer: {
                    Text("Discard only if you are sure those unresolved session changes should not be recovered.")
                }
            }

            if !model.pendingCreates.isEmpty {
                Section("Sessions waiting to send") {
                    ForEach(model.pendingCreates) { operation in
                        pendingRow(
                            title: model.summary(operation.sankalpaId)?.title ?? "Sankalpa",
                            kind: model.quarantinedCreateIds.contains(operation.id)
                                ? "Session needs attention" : "Session pending",
                            occurredAt: operation.occurredAt,
                            destination: operation.serviceInstanceId
                        )
                    }
                }
            }

            if !model.pendingDeletions.isEmpty {
                Section("Deletions pending") {
                    ForEach(model.pendingDeletions) { operation in
                        pendingRow(
                            title: model.summary(operation.sankalpaId)?.title ?? "Sankalpa",
                            kind: "Deletion pending",
                            occurredAt: operation.occurredAt,
                            destination: operation.serviceInstanceId
                        )
                    }
                }
            }

            if model.reliabilityProblem == nil && model.pendingSessionCount == 0 {
                ContentUnavailableView(
                    "No pending changes", systemImage: "checkmark.circle",
                    description: Text("Session changes are up to date.")
                )
            }
        }
        .navigationTitle("Pending Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .alert("Discard preserved session changes?", isPresented: $confirmingDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                model.discardUnrecoverableSessionChanges()
            }
        } message: {
            Text("This cannot be undone. Any session changes that existed only in the preserved journal will be lost.")
        }
    }

    private func pendingRow(
        title: String, kind: String, occurredAt: CalendarMoment, destination: UUID?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text("\(kind) · \(occurredAt.day.longDisplayText) at \(AppTime.timeText(occurredAt))")
                .font(.subheadline)
            Text("Service \(destination?.uuidString ?? "not yet verified")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Non-disruptive success feedback, paired with a haptic at the call site.
/// A just-logged session also carries the immediate Undo promised by the logging requirements.
private struct ConfirmationBanner: View {
    let text: String
    let showsUndo: Bool
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            if showsUndo {
                Button("Undo", action: undo)
                    .font(.subheadline.weight(.bold))
                    .buttonStyle(.plain)
                    .accessibilityHint("Permanently deletes the session that was just logged")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.satisfied, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.top, 8)
    }
}
