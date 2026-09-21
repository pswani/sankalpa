import SwiftUI
import SankalpaCore

/// Shown instead of the app when the store could not be opened.
///
/// Its whole job is to be honest and harmless: say what happened, make clear nothing was destroyed,
/// and offer to try again. Starting the app empty instead would be indistinguishable from a fresh
/// install, and would invite writing over data that is still on disk.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
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

            Button {
                model.retryLoadingStore()
            } label: {
                Text("Try opening again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
