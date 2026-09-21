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
            // A store that could not be read takes over the whole app. Showing an empty practice
            // instead would be indistinguishable from a fresh install, and inviting the user to
            // start declaring would write over data that is still recoverable.
            if let problem = model.storageProblem {
                RecoveryView(message: problem)
            } else {
                tabs
            }
        }
        .sheet(isPresented: $declaringSankalpa) {
            DeclareSankalpaView()
        }
        .alert(
            "That is not allowed",
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
        .overlay(alignment: .top) {
            if let confirmation = model.confirmation {
                ConfirmationBanner(
                    text: confirmation,
                    undo: model.undoableSession == nil ? nil : { model.undoLastSession() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: model.confirmationToken) {
                    // Long enough to notice and undo, short enough not to linger.
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

/// Non-disruptive success feedback, paired with a haptic at the call site.
///
/// When the action can be taken back, the banner carries the undo. Logging a session is one tap on
/// the largest control in the app, so the way out needs to be in the same place as the way in.
private struct ConfirmationBanner: View {
    let text: String
    var undo: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))

            if let undo {
                Divider()
                    .frame(height: 18)
                    .overlay(.white.opacity(0.45))
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
