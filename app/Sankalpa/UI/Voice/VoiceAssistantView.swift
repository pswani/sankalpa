import SankalpaVoice
import SwiftUI

struct VoiceAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var assistant: VoiceAssistantModel

    init(gateway: any VoiceCommandGateway) {
        _assistant = State(initialValue: VoiceAssistantModel(gateway: gateway))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    status
                    proposal
                    transcriptEditor
                    if let message = assistant.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("voice-status")
                    }
                    actions
                }
                .padding()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Speak to Sankalpa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task {
                            await assistant.cancel()
                            dismiss()
                        }
                    }
                    .disabled(assistant.isExecuting)
                }
            }
        }
        .interactiveDismissDisabled(assistant.isListening || assistant.isWorking || assistant.isExecuting)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await assistant.cancel() } }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: assistant.isListening ? "waveform" : "quote.bubble")
                .font(.largeTitle)
                .foregroundStyle(Palette.accent)
                .symbolEffect(.variableColor.iterative, isActive: assistant.isListening)
                .accessibilityHidden(true)
            Text(assistant.prompt)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voice-prompt")
        }
    }

    @ViewBuilder
    private var proposal: some View {
        switch assistant.state {
        case .reviewingSession(let proposal):
            VoiceSessionProposalView(proposal: proposal)
        case .reviewingDeclaration(let proposal):
            VoiceDeclarationProposalView(proposal: proposal)
        case .editingDeclaration(let draft, _), .choosingSavedDraft(let draft):
            VoiceDraftView(draft: draft)
        case .idle(let draft):
            if let draft { VoiceDraftView(draft: draft) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var transcriptEditor: some View {
        if !assistant.transcript.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recognized words")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $assistant.transcript)
                    .frame(minHeight: 90)
                    .padding(8)
                    .background(Palette.card, in: .rect(cornerRadius: 12))
                    .disabled(assistant.isListening || assistant.isWorking)
                    .accessibilityLabel("Recognized words. Edit to correct the transcript.")
                if !assistant.isListening {
                    Button("Apply correction") { Task { await assistant.applyCorrection() } }
                        .disabled(assistant.isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            switch assistant.state {
            case .choosingSavedDraft:
                Button("Resume draft") { Task { await assistant.resumeDraft() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Discard draft", role: .destructive) {
                    Task { await assistant.discardDraft() }
                }
                listenButton(label: "Speak your choice")
            case .idle(let draft) where draft != nil:
                Button("Resume draft") { Task { await assistant.resumeDraft() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Discard draft", role: .destructive) {
                    Task { await assistant.discardDraft() }
                }
                listenButton(label: "Log a session or speak your choice")
            case .reviewingSession, .reviewingDeclaration:
                Button("Confirm") { Task { await assistant.confirm() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(assistant.isWorking)
                listenButton(label: "Speak a revision")
            case .unavailable(.speechAssetsNeeded):
                Button("Download speech recognition") {
                    Task { await assistant.installSpeechAssets() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(assistant.isWorking)
            case .listening where assistant.isWorking:
                ProgressView("Finishing transcription…")
                    .controlSize(.large)
            case .executing:
                ProgressView().controlSize(.large)
            case .result:
                if assistant.undoReceipt != nil {
                    Button("Undo session") { Task { await assistant.undoSession() } }
                        .buttonStyle(AnyButtonStyle(.quiet))
                        .disabled(assistant.isWorking)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
            default:
                listenButton(label: assistant.isListening ? "Stop listening" : "Start listening")
            }

            if !assistant.isListening, case .idle = assistant.state {
                Text("Audio stays on this iPhone and is discarded after transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func listenButton(label: String) -> some View {
        Button {
            Task {
                if assistant.isListening { await assistant.stopListening() }
                else { await assistant.startListening() }
            }
        } label: {
            Label(label, systemImage: assistant.isListening ? "stop.fill" : "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(assistant.isWorking)
        .accessibilityIdentifier(assistant.isListening ? "voice-stop" : "voice-start")
    }
}
