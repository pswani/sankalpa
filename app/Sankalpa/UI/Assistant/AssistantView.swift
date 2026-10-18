import SwiftUI
import SankalpaConversation
import SankalpaCore
import SankalpaStorage

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @State private var session: AssistantSession
    @State private var speech = SpeechComposer()
    private let close: @MainActor () -> Void
    private let edit: @MainActor (AssistantProposal) -> Void

    init(appModel: AppModel,
         navigate: @escaping @MainActor @Sendable (UUID?) -> Void,
         close: @escaping @MainActor () -> Void,
         edit: @escaping @MainActor (AssistantProposal) -> Void) {
        self.close = close
        self.edit = edit
        let token = appModel.apiToken
        let client = AGUIClient(baseURL: appModel.serviceLocation.url, bearerToken: token,
                                linkedServiceInstance: appModel.supportsLinkedExtensions ? appModel.serviceInstanceId : nil,
                                batchSessions: appModel.assistantCapability?.batchSessionsVersion == 1)
        let recoveryURL = appModel.serviceInstanceId.map { instance in
            URL.applicationSupportDirectory.appending(path: "Assistant/\(instance.uuidString)-linked-v1.json")
        }
        _session = State(initialValue: AssistantSession(client: client, recoveryURL: recoveryURL, prepareSend: {
            await appModel.prepareAssistantRequest()
        }, handleTool: { tool in
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
        }))
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
                                    confirm: { Task { await confirm(proposal) } },
                                    cancel: { Task { await session.cancel() } },
                                    edit: {
                                        Task { if await session.cancel() { edit(proposal) } }
                                    }, disabled: session.isBusy, sharedEffects: sharedEffects(proposal))
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward") {
                        speech.stop()
                        close()
                    }
                }
            }
            .onChange(of: speech.transcript) { _, value in session.composer = value }
            .onDisappear { speech.stop() }
            .task { await session.recover() }
        }
    }

    private func sessionIdentity(_ proposal: AssistantProposal) -> (SankalpaId, SessionId)? {
        guard case .string(let owner)? = proposal.metadata["sankalpaId"], let ownerId = UUID(uuidString: owner),
              case .string(let id)? = proposal.metadata["sessionId"], let sessionId = UUID(uuidString: id) else { return nil }
        return (SankalpaId(ownerId), SessionId(sessionId))
    }
    private func sharedEffects(_ proposal: AssistantProposal) -> String? {
        guard let (owner, _) = sessionIdentity(proposal),
              case .string(let text)? = proposal.metadata["occurredAt"], let at = WireFormat.moment(from: text) else { return nil }
        return model.contributionPreview(owner: owner, at: at)
    }
    private func confirm(_ proposal: AssistantProposal) async {
        if proposal.kind == .logSession {
            guard let (owner, id) = sessionIdentity(proposal) else { return }
            await model.confirmAssistantSession(owner: owner, sessionId: id) { await session.confirm() }
        } else if proposal.kind == .logSessions {
            guard case .string(let owner)? = proposal.metadata["sankalpaId"], let id = UUID(uuidString: owner) else { return }
            await model.confirmAssistantBatch(owner: SankalpaId(id)) { await session.confirm() }
        } else { await session.confirm() }
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
                Button("Send") {
                    // Sending commits the reviewed transcript; recording must not continue in
                    // parallel or a late partial result can repopulate the cleared composer.
                    speech.stop()
                    Task { await session.send() }
                }
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
    var sharedEffects: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(proposal.kind == .unsupported ? "Update app to review this proposal" : proposal.kind == .logSessions ? "Confirm sessions" : proposal.kind == .logSession ? "Confirm session" : "Confirm Sankalpa",
                  systemImage: "checkmark.shield")
                .font(.headline)
            ForEach(rows, id: \.0) { key, value in LabeledContent(key, value: value) }
            if proposal.kind == .logSessions {
                DisclosureGroup("Review every session") {
                    ForEach(batchEntryRows, id: \.self) { Text($0).font(.footnote) }
                }
            }
            if let sharedEffects { Text(sharedEffects).font(.footnote) }
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                if proposal.kind != .logSessions && proposal.kind != .unsupported { Button("Edit", action: edit) }
                Spacer()
                if proposal.canConfirm {
                    Button(proposal.kind == .logSessions ? "Record \(proposal.newSessionCount) sessions" : "Confirm", action: confirm)
                        .buttonStyle(.borderedProminent)
                }
            }.disabled(disabled)
        }
        .padding().background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var batchEntryRows: [String] {
        var rows: [String] = []
        if case .array(let entries)? = proposal.batch["entries"] {
            rows += entries.compactMap { item in
                if case .object(let entry) = item, case .string(let time)? = entry["occurredAt"] { return "Add: " + time }
                return nil
            }
        }
        if case .array(let skipped)? = proposal.batch["skippedDays"] {
            rows += skipped.compactMap { item in
                if case .object(let day) = item, case .string(let date)? = day["date"] { return "Already recorded: " + date }
                return nil
            }
        }
        return rows
    }
    private var rows: [(String, String)] {
        if proposal.kind == .logSessions {
            let batch = proposal.batch
            let requested = batch["requestedCount"].map(text) ?? ""
            let skipped: Int = { if case .array(let values)? = batch["skippedDays"] { return values.count }; return 0 }()
            var rows = [("Sankalpa", proposal.metadata["sankalpaTitle"].map(text) ?? ""),
                        ("Sessions", "\(requested) requested / \(proposal.newSessionCount) new / \(skipped) already recorded"),
                        ("Timezone", batch["timezone"].map(text) ?? "")]
            if case .object(let plan)? = batch["plan"] {
                for key in ["from", "through", "localTime"] {
                    if let value = plan[key], value != .null { rows.append((label(key), text(value))) }
                }
            }
            if case .array(let repeats)? = batch["repeatWarnings"], !repeats.isEmpty {
                rows.append(("Repeated times", repeats.map(text).joined(separator: ", ") + ". These add separate sessions."))
            }
            return rows
        }
        if proposal.kind == .unsupported { return [] }
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
