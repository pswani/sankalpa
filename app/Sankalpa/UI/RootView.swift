import SwiftUI
import SankalpaCore

/// Named `AppTab` because SwiftUI's own `Tab` is the view used below.
enum AppTab: Hashable {
    case today, sankalpas, journal
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab: AppTab = .today
    @State private var declaringSankalpa = false
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
        .safeAreaInset(edge: .top) {
            // Saying the practice may be behind matters more than it looks: without it, a session
            // logged offline and a session the service has taken are indistinguishable, and the
            // user has no way to know whether their practice is actually recorded anywhere but
            // this phone.
            if model.isShowingCachedPractice || model.pendingSessionCount > 0 {
                OfflineNotice(
                    isCached: model.isShowingCachedPractice,
                    pendingCount: model.pendingSessionCount
                )
            }
        }
        .overlay(alignment: .top) {
            if let confirmation = model.confirmation {
                ConfirmationBanner(text: confirmation)
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

    private var text: String {
        switch (isCached, pendingCount) {
        case (_, let waiting) where waiting > 0 && isCached:
            return "Showing this phone's copy · \(waiting) session\(waiting == 1 ? "" : "s") waiting to be sent"
        case (false, let waiting) where waiting > 0:
            return "\(waiting) session\(waiting == 1 ? "" : "s") waiting to be sent"
        default:
            return "Showing this phone's copy — the service could not be reached"
        }
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
/// It used to carry an Undo for a session just logged. The service has no way to remove a logged
/// session — deleting one is deliberately outside the requirements — so offering to take it back
/// would be a promise the app cannot keep.
private struct ConfirmationBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.satisfied, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.top, 8)
    }
}
