import SwiftUI
import SankalpaConversation

struct AssistantView: View {
    @State private var session: AssistantSession
    @State private var speech = SpeechComposer()
    private let edit: @MainActor (AssistantProposal) -> Void

    init(appModel: AppModel,
         navigate: @escaping @MainActor @Sendable (UUID?) -> Void,
         edit: @escaping @MainActor (AssistantProposal) -> Void) {
        self.edit = edit
        let token = appModel.apiToken
        let client = AGUIClient(baseURL: appModel.serviceLocation.url, bearerToken: token)
        _session = State(initialValue: AssistantSession(client: client) { tool in
            switch tool.name {
            case "refresh_practice":
                await appModel.refresh()
                return !appModel.isShowingCachedPractice
            case "navigate_to_sankalpa":
                if case .object(let args) = tool.arguments,
                   case .string(let value)? = args["sankalpaId"], let id = UUID(uuidString: value) {
                    navigate(id); return true
                }
                return false
            case "open_sankalpa_list": navigate(nil); return true
            default: return false
            }
        })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if session.transcript.isEmpty {
                                ContentUnavailableView("Ask Sankalpa", systemImage: "bubble.left.and.text.bubble.right",
                                    description: Text("Ask about your practice, log a session, or propose a new Sankalpa."))
                            }
                            ForEach(session.transcript) { message in bubble(message) }
                            if case .awaitingConfirmation(let proposal) = session.state {
                                ProposalCard(proposal: proposal,
                                    confirm: { Task { await session.confirm() } },
                                    cancel: { Task { await session.cancel() } },
                                    edit: {
                                        Task { if await session.cancel() { edit(proposal) } }
                                    }, disabled: session.isBusy)
                            }
                            if let message = session.errorMessage {
                                Label(message, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange).font(.callout)
                            }
                            if session.staleAfterSave {
                                Text("Saved, but the practice could not be refreshed. Pull to refresh when connected.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }.padding().id(session.transcript.count)
                    }
                    .onChange(of: session.transcript.count) { _, _ in
                        withAnimation { proxy.scrollTo(session.transcript.count, anchor: .bottom) }
                    }
                }
                Divider()
                composer
            }
            .navigationTitle("Assistant")
            .onChange(of: speech.transcript) { _, value in session.composer = value }
            .onDisappear { speech.stop() }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Message", text: $session.composer, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
                .disabled(session.isBusy)
            HStack {
                Button { speech.toggle() } label: {
                    Label(speech.isListening ? "Stop listening" : "Speak",
                          systemImage: speech.isListening ? "stop.circle.fill" : "mic.circle")
                }.accessibilityHint("Recognized words remain editable and are not sent automatically")
                Spacer()
                if session.isBusy { ProgressView().accessibilityLabel("Understanding") }
                Button("Send") { Task { await session.send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isBusy)
            }
            if speech.isListening { Text("Listening… Stop, review the text, then tap Send.").font(.caption).foregroundStyle(.secondary) }
            if let message = speech.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.padding()
    }

    private func bubble(_ message: AGUI.Message) -> some View {
        Text(message.content)
            .padding(12)
            .background(message.role == "user" ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
            .accessibilityLabel("\(message.role == "user" ? "You" : "Assistant"): \(message.content)")
    }
}

private struct ProposalCard: View {
    let proposal: AssistantProposal
    let confirm: () -> Void
    let cancel: () -> Void
    let edit: () -> Void
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(proposal.kind == .logSession ? "Confirm session" : "Confirm Sankalpa",
                  systemImage: "checkmark.shield")
                .font(.headline)
            ForEach(rows, id: \.0) { key, value in LabeledContent(key, value: value) }
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Button("Edit", action: edit)
                Spacer()
                Button("Confirm", action: confirm).buttonStyle(.borderedProminent)
            }.disabled(disabled)
        }
        .padding().background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var rows: [(String, String)] {
        let keys = proposal.kind == .logSession
            ? ["sankalpaTitle", "occurredAt", "userSummary"]
            : ["title", "description", "actionType", "startDate", "periodUnit", "timesPerPeriod", "periodCount"]
        return keys.compactMap { key in
            proposal.metadata[key].map { (label(key) + (inferredFields.contains(key) ? " (suggested)" : ""), text($0)) }
        }
    }
    private var inferredFields: Set<String> {
        guard case .array(let values)? = proposal.metadata["inferredFields"] else { return [] }
        return Set(values.compactMap { if case .string(let value) = $0 { value } else { nil } })
    }
    private func text(_ value: JSONValue) -> String {
        switch value { case .string(let v): v; case .number(let v): v.formatted(); case .bool(let v): String(v); case .null: "Open-ended"; default: "" }
    }
    private func label(_ key: String) -> String {
        key.replacingOccurrences(of: "sankalpa", with: "Sankalpa ").replacingOccurrences(of: "At", with: " at").capitalized
    }
}
