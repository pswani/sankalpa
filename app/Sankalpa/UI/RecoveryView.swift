import SwiftUI
import SankalpaCore

/// Shown instead of the app when the store could not be opened.
///
/// Its job is to be honest, harmless, and *escapable*. Saying what happened and refusing to write
/// over the file is right; leaving that as the only thing the screen can do is not, because every
/// write is refused while the file is unreadable and deleting the app is then the only way back to
/// a usable one — which destroys the bytes this screen promises are still there.
///
/// So there are three ways forward, in the order worth trying them: open it again in case the
/// failure was transient, take a copy of the file out of the app, and start fresh with the damaged
/// file renamed rather than removed.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    let message: String

    @State private var confirmingStartFresh = false
    /// Set when a retry left the store exactly as unreadable as before, so the button answers
    /// instead of appearing to do nothing.
    @State private var lastAttemptFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Palette.pausedTint)
                    .accessibilityHidden(true)

                Text("Your data needs attention")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    Button {
                        model.retryLoadingStore()
                        lastAttemptFailed = model.storageProblem != nil
                    } label: {
                        Text("Try opening again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)

                    if let fileURL = model.exportableFileURL {
                        ShareLink(item: fileURL) {
                            Label("Save a copy of the file", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.quiet)
                    }

                    Button {
                        confirmingStartFresh = true
                    } label: {
                        Text("Start fresh…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.quiet(tint: Palette.missed))
                }
                .padding(.top, 4)

                if lastAttemptFailed {
                    // A button that changes nothing twice reads as a broken button.
                    Text("It still could not be opened. Save a copy first if you want to keep the file, then start fresh.")
                        .font(.footnote)
                        .foregroundStyle(Palette.missed)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .confirmationDialog(
            "Start fresh?",
            isPresented: $confirmingStartFresh,
            titleVisibility: .visible
        ) {
            Button("Start fresh", role: .destructive) {
                model.startFreshPreservingUnreadableFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The renamed file stays inside the app's own container, which nothing on the phone
            // can browse — so "it is kept" is true and not much use on its own. Saving a copy is
            // the step that actually keeps it, and it has to happen first.
            Text("The app will open empty. The file that could not be read is renamed and kept, not deleted, but the app will not offer it again — save a copy first if you want it.")
        }
    }
}
