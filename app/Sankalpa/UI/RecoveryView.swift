import SwiftUI
import SankalpaCore

/// Shown instead of the app when the Sankalpa service has never been reached.
///
/// Its job is to be honest and escapable. An empty practice would be indistinguishable from a
/// first run with nothing declared, and inviting someone to declare into a service that is not
/// answering would lose whatever they typed — so the app says what is wrong, says where it was
/// looking, and offers to try again.
///
/// It shows only when the phone has nothing cached either — once a refresh has succeeded, its copy
/// is what gets rendered and a later failure becomes a notice over it rather than a takeover. So
/// the two things worth offering here are trying again, and correcting the computer it is looking
/// for, which on a real phone is the usual reason there is nothing to show.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    let message: String

    /// Set when a retry left the service exactly as unreachable as before, so the button answers
    /// instead of appearing to do nothing.
    @State private var lastAttemptFailed = false
    @State private var isRetrying = false
    @State private var changingService = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Palette.pausedTint)
                    .accessibilityHidden(true)

                Text("Your practice is out of reach")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task {
                        isRetrying = true
                        await model.retryConnection()
                        isRetrying = false
                        lastAttemptFailed = model.connectionProblem != nil
                    }
                } label: {
                    Group {
                        if isRetrying {
                            ProgressView()
                        } else {
                            Text("Try again")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .disabled(isRetrying)
                .padding(.top, 4)

                // The commonest reason this screen is showing on a real phone is that the app is
                // looking at the wrong computer, so the way to fix that belongs here rather than
                // behind a tab the person cannot reach yet.
                Button("Change computer…") { changingService = true }
                    .buttonStyle(.quiet)

                if lastAttemptFailed {
                    // A button that changes nothing twice reads as a broken button.
                    VStack(spacing: 6) {
                        Text("It still could not be reached.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.missed)
                        // Naming the address is the difference between a dead end and something
                        // the person can actually check.
                        Text("Looking for the Sankalpa service on \(model.serviceLocation.displayText).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $changingService) {
            ServiceSettingsView()
        }
    }
}
