import SwiftUI
import SankalpaCore
import SankalpaStorage

struct ExtendSankalpaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: Sankalpa
    let accepted: (SankalpaId) -> Void
    @FocusState private var durationFocused: Bool
    @State private var totalDuration = ""
    @State private var submitting = false
    @State private var message: String?

    private var preview: Sankalpa? {
        guard let count = Int(totalDuration) else { return nil }
        return try? source.extended(totalPeriodCount: count, now: model.now())
    }

    private var validationMessage: String? {
        guard !totalDuration.isEmpty else { return nil }
        guard let count = Int(totalDuration) else { return "Enter a whole number of periods." }
        do { _ = try source.extended(totalPeriodCount: count, now: model.now()); return nil }
        catch let error as any DomainError { return error.message }
        catch { return "Check the proposed total duration." }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("A longer commitment") {
                    LabeledContent("Current duration", value: source.commitment.durationValueText)
                    LabeledContent("Original start", value: source.startDate.longDisplayText)
                    LabeledContent("Current end", value: source.endDate?.longDisplayText ?? "Ongoing")
                    TextField("Total duration", text: $totalDuration)
                        .keyboardType(.numberPad)
                        .focused($durationFocused)
                        .accessibilityIdentifier("extensionTotalDuration")
                        .accessibilityLabel("Total duration in " + source.commitment.periodUnit.pluralName(2))
                    Text("Total \(source.commitment.periodUnit.pluralName(2)) from the original start, including the current commitment.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let preview {
                        LabeledContent("New total", value: preview.commitment.durationValueText)
                        LabeledContent("New end", value: preview.endDate!.longDisplayText)
                    } else if let validationMessage {
                        Text(validationMessage).font(.footnote).foregroundStyle(Palette.missed)
                    }
                }
                Section("What carries forward") {
                    Text(source.commitment.frequencyPhrase)
                    Text("The new vow begins \(source.state.displayName.lowercased()), with the same past lifecycle. Past and future eligible sessions count toward both vows.")
                    Text("Each vow can be paused and completed independently. Your original commitment remains intact.")
                }
                if let message { Section { Text(message).foregroundStyle(.orange) } }
                Section {
                    Button {
                        guard let count = Int(totalDuration), !submitting else { return }
                        submitting = true
                        Task {
                            let result = await model.extend(source.id, totalPeriodCount: count)
                            submitting = false
                            switch result {
                            case .accepted(let id, _): dismiss(); accepted(id)
                            case .pending(let text), .refused(let text), .blocked(let text): message = text
                            }
                        }
                    } label: {
                        if submitting { ProgressView("Extending…") } else { Text("Create extended sankalpa") }
                    }
                    .disabled(preview == nil || submitting || model.hasExtensionAttempt || !model.isServiceReachable)
                    .accessibilityIdentifier("submitExtension")
                    if !model.isServiceReachable { Text("Connect to the service to create an extension.").font(.footnote) }
                }
            }
            .navigationTitle("Extend sankalpa")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(submitting) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { durationFocused = false } }
            }
            .interactiveDismissDisabled(submitting)
            .onAppear { totalDuration = String((source.commitment.periodCount?.value ?? 0) + 1) }
        }
    }
}
