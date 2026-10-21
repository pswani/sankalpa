import SwiftUI
import SankalpaConversation
import SankalpaCore
import SankalpaStorage

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var speech = SpeechComposer()
    @State private var showingConversations = false
    private let close: @MainActor () -> Void
    private let edit: @MainActor (AssistantProposal) -> Void
    private let pendingChanges: @MainActor () -> Void
    private let navigate: @MainActor @Sendable (UUID?) -> Void

    init(appModel: AppModel,
         navigate: @escaping @MainActor @Sendable (UUID?) -> Void,
         close: @escaping @MainActor () -> Void,
         edit: @escaping @MainActor (AssistantProposal) -> Void,
         pendingChanges: @escaping @MainActor () -> Void) {
        self.close = close; self.edit = edit; self.navigate = navigate; self.pendingChanges = pendingChanges
    }

    var body: some View {
        NavigationStack {
            if let controller = model.assistant {
                conversation(controller)
                    .navigationTitle(controller.session?.title ?? "Assistant")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back", systemImage: "chevron.backward") {
                                stopSpeech()
                                Task { if await controller.flushDraft() { close() } }
                            }
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button("Conversations", systemImage: "list.bullet") {
                                stopSpeech()
                                Task { if await controller.flushDraft() { showingConversations = true } }
                            }
                            .accessibilityIdentifier("assistant-conversations")
                            Button("New conversation", systemImage: "square.and.pencil") {
                                stopSpeech()
                                Task { await controller.newConversation() }
                            }
                            .accessibilityIdentifier("assistant-new")
                            .disabled(!controller.canNavigate || controller.storageProblem != nil)
                        }
                    }
                    .sheet(isPresented: $showingConversations) { history(controller) }
                    .onChange(of: controller.pendingNavigation?.id) { _, _ in
                        guard let tool = controller.consumeNavigation() else { return }
                        if tool.name == "open_sankalpa_list" { navigate(nil) }
                        else if tool.name == "navigate_to_sankalpa", case .object(let args) = tool.arguments,
                                case .string(let id)? = args["sankalpaId"], let uuid = UUID(uuidString: id) { navigate(uuid) }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase != .active { stopSpeech(); Task { await controller.flushDraft() } }
                    }
                    .onDisappear { stopSpeech(); Task { await controller.flushDraft() } }
            } else { ProgressView("Opening conversations…") }
        }
    }

    @ViewBuilder private func conversation(_ controller: AssistantConversationController) -> some View {
        VStack(spacing: 0) {
            if model.pendingSessionCount > 0 || model.reliabilityProblem != nil || model.hasExtensionAttempt {
                Button("Pending practice changes need attention", action: pendingChanges).font(.callout).padding(.horizontal)
            }
            if let problem = controller.storageProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).padding()
                Button("Retry loading history") { Task { await controller.reloadStorage() } }
            }
            if let problem = controller.networkProblem { Text(problem).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            if let recovery = controller.recoveryConversationId {
                Button("A conversation needs recovery — Open conversation") {
                    stopSpeech(); Task { await controller.select(recovery) }
                }.disabled(!controller.canNavigate).padding(.horizontal)
            }
            if let session = controller.session {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if session.transcript.isEmpty {
                                ContentUnavailableView("Ask Sankalpa", systemImage: "bubble.left.and.text.bubble.right",
                                    description: Text("Ask about your practice, log a session, or propose a new Sankalpa."))
                            }
                            if session.record.imported { Text("Earlier messages may be unavailable").font(.caption).foregroundStyle(.secondary) }
                            if session.transcript.count > 20 { Text("Earlier messages may be outside the assistant’s context").font(.caption).foregroundStyle(.secondary) }
                            ForEach(session.transcript) { message in bubble(message).id(message.id) }
                            if session.needsRecovery {
                                Button(session.staleAfterSave ? "Retry practice refresh" : "Retry request") {
                                    stopSpeech(); Task { await controller.retry() }
                                }.disabled(!controller.canRetry)
                            } else if let proposal = session.proposal {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    ProposalCard(proposal: proposal,
                                        confirm: { stopSpeech(); Task { await confirm(controller) } },
                                        cancel: { stopSpeech(); Task { await controller.cancel() } },
                                        edit: {
                                            stopSpeech()
                                            Task { if await controller.cancel(edit: true) { edit(proposal) } }
                                        }, disabled: !controller.canSend, expired: session.proposalExpired(at: context.date),
                                        sharedEffects: sharedEffects(proposal))
                                }
                            } else if let proposal = session.record.editProposal {
                                Button("Continue editing proposal") { edit(proposal) }
                                Button("Dismiss edit") { Task { await controller.dismissEdit() } }
                            }
                            if let message = session.errorMessage {
                                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                            }
                            if session.staleAfterSave {
                                Text("Saved, but the practice could not be refreshed. Retry when connected.").font(.footnote).foregroundStyle(.secondary)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding()
                    }
                    .id(session.threadId)
                    .onChange(of: session.transcript.count) { _, _ in
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                Divider()
                composer(controller, session: session)
            } else if controller.isLoading { ProgressView() }
        }
    }

    private func history(_ controller: AssistantConversationController) -> some View {
        NavigationStack {
            List {
                Section {
                    Button("New conversation", systemImage: "square.and.pencil") {
                        Task { await controller.newConversation(); if controller.storageProblem == nil { showingConversations = false } }
                    }.disabled(!controller.canNavigate || controller.storageProblem != nil)
                } footer: { Text("Conversations are saved on this device.") }
                Section {
                    ForEach(controller.conversations) { summary in
                        Button {
                            Task { await controller.select(summary.id); if controller.session?.threadId == summary.id { showingConversations = false } }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.title).font(.headline).foregroundStyle(.primary)
                                Text(summary.activityAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                if !summary.preview.isEmpty { Text(summary.preview).lineLimit(2).foregroundStyle(.secondary) }
                                if let status = summary.status { Text(status).font(.caption).foregroundStyle(.orange) }
                            }
                        }.buttonStyle(.plain)
                        .disabled(!controller.canNavigate)
                        .accessibilityHint("Continue this conversation")
                        .accessibilityIdentifier("conversation-\(summary.id.uuidString)")
                    }
                    ForEach(controller.damagedFiles, id: \.self) { file in
                        Label("History unavailable: \(file)", systemImage: "exclamationmark.triangle").font(.callout)
                    }
                }
                if controller.isBusy { Text("Finish this response before switching conversations").font(.footnote) }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingConversations = false } } }
        }
    }

    private func toggleSpeech(_ controller: AssistantConversationController, owner: UUID) {
        speech.onTranscript = { [weak controller] text in
            guard let controller, controller.session?.threadId == owner, !controller.isBusy else { return }
            controller.updateDraft(text)
        }
        speech.toggle()
    }
    private func stopSpeech() { speech.stop(); speech.onTranscript = nil }
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
    private func confirm(_ controller: AssistantConversationController) async {
        await controller.confirm { proposal, action in
            if proposal.kind == .logSession {
                guard let (owner, id) = sessionIdentity(proposal) else { return }
                await model.confirmAssistantSession(owner: owner, sessionId: id, action: action)
            } else if proposal.kind == .logSessions {
                guard case .string(let owner)? = proposal.metadata["sankalpaId"], let id = UUID(uuidString: owner) else { return }
                await model.confirmAssistantBatch(owner: SankalpaId(id), action: action)
            } else { await action() }
        }
    }
    private func composer(_ controller: AssistantConversationController, session: AssistantSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Message", text: Binding(get: { session.composer }, set: { controller.updateDraft($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
                .accessibilityIdentifier("assistant-message")
                .disabled(controller.isBusy)
            HStack {
                Button {
                    toggleSpeech(controller, owner: session.threadId)
                } label: {
                    Label(speech.isListening ? "Stop listening" : "Speak", systemImage: speech.isListening ? "stop.circle.fill" : "mic.circle")
                }.accessibilityHint("Recognized words remain editable and are not sent automatically")
                .disabled(controller.isBusy)
                Spacer()
                if controller.isBusy { ProgressView().accessibilityLabel("Understanding") }
                Button("Send") { stopSpeech(); Task { await controller.send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.canSend)
            }
            if speech.isListening { Text("Listening… Stop, review the text, then tap Send.").font(.caption).foregroundStyle(.secondary) }
            if let message = speech.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.padding()
    }
    private func bubble(_ message: AGUI.Message) -> some View {
        Text(message.role == "assistant"
             ? (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.content)
             : AttributedString(message.content))
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
    var expired = false
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
            if expired { Text("Expired — ask again").font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button(expired ? "Ask again" : "Cancel", role: .cancel, action: cancel)
                if !expired && proposal.kind != .logSessions && proposal.kind != .unsupported { Button("Edit", action: edit) }
                Spacer()
                if proposal.canConfirm && !expired {
                    Button(proposal.kind == .logSessions ? (proposal.batch["beginAdjustment"] != nil && proposal.batch["beginAdjustment"] != .null ? "Confirm Begin correction and record \(proposal.newSessionCount) sessions" : "Record \(proposal.newSessionCount) sessions") : "Confirm", action: confirm)
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
            if case .object(let adjustment)? = batch["beginAdjustment"] {
                rows.append(("Correct recorded Begin", (adjustment["previousEffectiveAt"].map(text) ?? "") + " → " + (adjustment["correctedEffectiveAt"].map(text) ?? "")))
                rows.append(("Audit history", "The original Begin time will be preserved with this correction."))
            }
            if case .object(let plan)? = batch["plan"] {
                if plan["recordingTimeSuggested"] == .bool(true) {
                    rows.append(("Suggested recording time", "00:01 for each observed day. This is a recording convention, not an exact performance time."))
                }
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
