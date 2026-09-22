import SwiftUI
import SankalpaCore
import SankalpaStorage

/// Where to find the computer running the Sankalpa service.
///
/// On the simulator the service is on the same machine, so `localhost` works and most people never
/// open this. On a real phone it never works — `localhost` is the phone — and the name of the Mac
/// is the only thing that can find it. Nobody but the person holding the phone knows that name, so
/// it has to be askable.
struct ServiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isChecking = false
    /// Set when what was typed is not a name this app can use, so the refusal sits with the field.
    @State private var problem: String?

    /// What was typed, once it reads as somewhere to look.
    private var location: ServiceLocation? { ServiceLocation(text: text) }

    private var hasChanged: Bool { location != nil && location != model.serviceLocation }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("studio.local", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .onChange(of: text) { problem = nil }
                } header: {
                    Text("Computer")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(Palette.missed)
                    } else {
                        // The port is interpolated as text on purpose: `Text` number-formats an
                        // Int, and "8,080" is not a port anyone can type.
                        Text(
                            """
                            The name of the computer running the Sankalpa service — for example \
                            studio.local. Add a port after a colon if it is not \
                            \(String(ServiceLocation.defaultPort)).
                            """
                        )
                    }
                }

                if model.serviceLocationIsOverridden {
                    Section {
                        Label(
                            """
                            A launch setting is deciding where to look, so this is not being used \
                            right now.
                            """,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("In use", value: model.serviceLocation.displayText)
                    if model.pendingSessionCount > 0 {
                        LabeledContent(
                            "Waiting to be sent",
                            value: "\(model.pendingSessionCount) session\(model.pendingSessionCount == 1 ? "" : "s")"
                        )
                    }
                } footer: {
                    if model.pendingSessionCount > 0 {
                        // These exist nowhere else, so switching computers must not read as
                        // throwing them away.
                        Text(
                            """
                            Sessions logged while the service was out of reach are kept on this \
                            phone and sent when it answers. Changing the computer keeps them.
                            """
                        )
                    }
                }
            }
            .navigationTitle("Sankalpa service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isChecking { ProgressView() } else { Text("Save") }
                    }
                    .fontWeight(.semibold)
                    .disabled(!hasChanged || isChecking)
                }
            }
            .onAppear { text = model.serviceLocation.displayText }
        }
    }

    private func save() {
        guard let location else {
            problem = "That is not the name of a computer. Try something like studio.local."
            return
        }
        guard location != model.serviceLocation else { return dismiss() }
        isChecking = true
        Task {
            await model.useService(at: location)
            isChecking = false
            dismiss()
        }
    }
}
