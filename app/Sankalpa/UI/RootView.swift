import SwiftUI
import SankalpaCore
import SankalpaVoice

/// Named `AppTab` because SwiftUI's own `Tab` is the view used below.
enum AppTab: Hashable {
    case today, sankalpas, journal
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab: AppTab = .today
    @State private var declaringSankalpa = false
    @State private var showingVoiceAssistant = false
    @State private var voiceDraftWaiting = false
    @State private var listFilter: SankalpaListView.Filter = .active

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
        .sheet(isPresented: $showingVoiceAssistant, onDismiss: refreshVoiceDraftIndicator) {
            VoiceAssistantView(gateway: model)
        }
        .alert(
            model.alertTitle,
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            presenting: model.alertMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "A session was just logged. Log another?",
            isPresented: Binding(
                get: { model.repeatLogRequest != nil },
                set: { if !$0 { model.cancelRapidRepeat() } }
            )
        ) {
            Button("Confirm another session") { model.confirmRapidRepeat() }
            Button("Cancel", role: .cancel) { model.cancelRapidRepeat() }
        }
        .safeAreaInset(edge: .top) {
            // Saying the practice may be behind matters more than it looks: without it, a session
            // logged offline and a session the service has taken are indistinguishable, and the
            // user has no way to know whether their practice is actually recorded anywhere but
            // this phone.
            if model.isShowingCachedPractice || model.pendingSessionCount > 0
                || model.pendingDeletionCount > 0 {
                OfflineNotice(
                    isCached: model.isShowingCachedPractice,
                    pendingCount: model.pendingSessionCount,
                    deletionCount: model.pendingDeletionCount
                )
            }
        }
        .overlay(alignment: .top) {
            if let confirmation = model.confirmation {
                ConfirmationBanner(
                    text: confirmation,
                    canUndo: model.undoReceipt != nil,
                    undo: model.undoLastSession
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: model.confirmationToken) {
                    // Long enough to notice, short enough not to linger.
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation(.snappy) { model.clearConfirmation() }
                }
            }
        }
        .animation(.snappy, value: model.confirmation)
        .sensoryFeedback(.success, trigger: model.successCount)
        .overlay(alignment: .bottomTrailing) {
            Button {
                showingVoiceAssistant = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "mic.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.onAccentFill)
                        .frame(width: 56, height: 56)
                        .background(Palette.accentFill, in: .circle)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    if voiceDraftWaiting {
                        Circle()
                            .fill(Palette.pausedTint)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Palette.card, lineWidth: 2))
                    }
                }
            }
            .accessibilityLabel("Speak to Sankalpa")
            .accessibilityHint("Log a session or prepare a new Sankalpa by voice")
            .padding(.trailing, 18)
            .padding(.bottom, 76)
        }
        .task { refreshVoiceDraftIndicator() }
    }

    private func refreshVoiceDraftIndicator() {
        voiceDraftWaiting = VoiceDraftStore().hasDraft()
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
    let deletionCount: Int

    private var text: String {
        var parts: [String] = []
        if isCached { parts.append("Showing this phone's copy") }
        if pendingCount > 0 {
            parts.append("\(pendingCount) session\(pendingCount == 1 ? "" : "s") waiting to be sent")
        }
        if deletionCount > 0 {
            parts.append("\(deletionCount) deletion\(deletionCount == 1 ? "" : "s") waiting to sync")
        }
        if parts.isEmpty { return "The service could not be reached" }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Palette.pausedTint)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// Non-disruptive success feedback, paired with a haptic at the call site.
///
/// The optional Undo is present only for the most recently logged session and shares this banner's
/// four-second lifetime.
private struct ConfirmationBanner: View {
    let text: String
    let canUndo: Bool
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            if canUndo {
                Button("Undo", action: undo)
                    .font(.subheadline.weight(.bold))
                    .buttonStyle(.plain)
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
