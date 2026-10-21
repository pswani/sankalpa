import Foundation
import Observation

@MainActor @Observable
public final class AssistantConversationController {
    public private(set) var session: AssistantSession?
    public private(set) var conversations: [AssistantConversationSummary] = []
    public private(set) var damagedFiles: [String] = []
    public private(set) var storageProblem: String?
    public private(set) var isBusy = false
    public private(set) var isLoading = false
    public private(set) var pendingNavigation: FrontendToolCall?
    public let serviceInstanceId: UUID
    private let store: AssistantConversationStore
    private let negotiation: AssistantNegotiation
    private let makeClient: @MainActor @Sendable (AssistantNegotiation) -> any AssistantRunClient
    private let availability: @MainActor @Sendable () -> String?
    private let prepareSend: @MainActor @Sendable () async -> Bool
    private let refresh: @MainActor @Sendable () async -> Bool
    private let clock: @Sendable () -> Date
    private let maximumMessages: Int
    private let maximumRequestBytes: Int
    private var draftTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var generation = 0
    private var invalidated = false
    private var loaded = false
    private var draftGeneration = 0
    private var navigationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: AssistantConversationStore, negotiation: AssistantNegotiation = .init(),
                maximumMessages: Int = 20, maximumRequestBytes: Int = 262_144,
                makeClient: @escaping @MainActor @Sendable (AssistantNegotiation) -> any AssistantRunClient,
                availability: @escaping @MainActor @Sendable () -> String? = { nil },
                prepareSend: @escaping @MainActor @Sendable () async -> Bool = { true },
                refresh: @escaping @MainActor @Sendable () async -> Bool = { true },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.serviceInstanceId = store.serviceInstanceId; self.negotiation = negotiation
        self.maximumMessages = max(1, min(20, maximumMessages)); self.maximumRequestBytes = max(1, min(262_144, maximumRequestBytes))
        self.makeClient = makeClient; self.availability = availability; self.prepareSend = prepareSend
        self.refresh = refresh; self.clock = clock
    }
    public var networkProblem: String? { invalidated ? "Reconnect the service to use this conversation." : availability() }
    public var recoveryConversationId: UUID? { conversations.first(where: \.needsRecovery)?.id }
    public var canSend: Bool { !isBusy && !isLoading && loaded && storageProblem == nil && networkProblem == nil && recoveryConversationId == nil }
    public var canNavigate: Bool { !isBusy && !isLoading && loaded && !invalidated }
    public var canRetry: Bool {
        !isBusy && !isLoading && loaded && storageProblem == nil && networkProblem == nil && session?.needsRecovery == true
    }

    public func open() async {
        guard !loaded, !isLoading, !invalidated else { return }
        isLoading = true
        let library = await store.open(now: clock())
        guard !invalidated else { finishLoading(); return }
        apply(library); loaded = true; finishLoading()
    }
    public func reloadStorage() async {
        guard !isBusy, !isLoading, !invalidated else { return }
        let draft = session.map { ($0.threadId, $0.composer) }
        loaded = false
        await open()
        if let draft, session?.threadId == draft.0 { updateDraft(draft.1) }
    }
    private func finishLoading() {
        isLoading = false
        let waiters = navigationWaiters; navigationWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    private func apply(_ library: AssistantConversationStore.Library) {
        conversations = library.summaries; damagedFiles = library.damagedFiles; storageProblem = library.problem
        if let record = library.selected { session = AssistantSession(record: record) }
    }
    private func updateSummary(_ record: AssistantConversationRecord) {
        if let current = conversations.first(where: { $0.id == record.id }), current.revision > record.revision { return }
        conversations.removeAll { $0.id == record.id }; conversations.append(.init(record))
        conversations.sort {
            if $0.activityAt != $1.activityAt { return $0.activityAt > $1.activityAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    public func updateDraft(_ value: String) {
        guard let session, !invalidated else { return }
        session.composer = value
        draftGeneration += 1
        let version = draftGeneration
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.draftGeneration == version else { return }
            _ = await self.flushDraft()
        }
    }
    @discardableResult
    public func flushDraft() async -> Bool {
        draftTask?.cancel(); draftTask = nil
        guard let session, session.composer != session.record.draft else { return true }
        let value = session.composer, version = draftGeneration
        do {
            let saved = try await store.saveDraft(value, id: session.threadId, now: clock())
            // No full-record write from a draft snapshot. A concurrent run may have advanced state.
            if session.record.revision <= saved.revision { session.record = saved }
            updateSummary(saved)
            if draftGeneration == version { session.composer = value }
            return true
        } catch { showStorageError(error); return false }
    }
    public func newConversation() async {
        guard canNavigate, storageProblem == nil else { return }
        isLoading = true; defer { finishLoading() }
        guard await flushDraft(), !invalidated else { return }
        if session?.record.isEmpty == true { return }
        do {
            let record = try await store.create(now: clock())
            guard !invalidated else { return }
            session = AssistantSession(record: record); pendingNavigation = nil; updateSummary(record)
        } catch { showStorageError(error) }
    }
    public func select(_ id: UUID) async {
        guard canNavigate else { return }
        isLoading = true; defer { finishLoading() }
        guard await flushDraft(), !invalidated else { return }
        do {
            let record = try await store.load(id)
            try await store.select(id)
            guard !invalidated else { return }
            session = AssistantSession(record: record); pendingNavigation = nil
        } catch { showStorageError(error) }
    }
    /// Flush and interrupt before changing endpoint/credentials. An interrupted stream is not cancellation.
    @discardableResult
    public func suspend() async -> Bool {
        guard await flushDraft() else { return false }
        invalidated = true; generation += 1; draftTask?.cancel(); activeTask?.cancel()
        await activeTask?.value
        if isLoading { await withCheckedContinuation { navigationWaiters.append($0) } }
        pendingNavigation = nil
        return true
    }
    public func consumeNavigation() -> FrontendToolCall? {
        defer { pendingNavigation = nil }
        return pendingNavigation
    }
    public func dismissEdit() async {
        guard !isBusy, !isLoading, let session, session.record.editProposal != nil else { return }
        var record = session.record; record.editProposal = nil
        _ = await persist(record, in: session)
    }

    public func send() async {
        guard canSend, let session else { return }
        let text = session.composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await owned(session) {
            if session.proposal != nil {
                var record = session.record; record.queuedCorrection = text
                guard await self.persist(record, in: session) else { return }
                let success = await self.startDecision(.cancel, in: session)
                if success, !self.invalidated, session.record.request == nil, session.proposal == nil {
                    await self.startOrdinary(in: session)
                }
            } else { await self.startOrdinary(in: session) }
        }
    }
    /// Reserve before entering any UI repeat-confirmation policy, so navigation cannot change the owner.
    public func confirm(policy: @escaping @MainActor (AssistantProposal, @escaping @MainActor () async -> Void) async -> Void = { _, action in await action() }) async {
        guard canSend, let session, let proposal = session.proposal, proposal.canConfirm,
              !session.proposalExpired(at: clock()) else { return }
        await owned(session) {
            await policy(proposal) {
                guard !self.invalidated else { return }
                _ = await self.startDecision(.confirm, in: session)
            }
        }
    }
    @discardableResult
    public func cancel(edit: Bool = false) async -> Bool {
        guard canSend, let session, let proposal = session.proposal else { return false }
        var success = false
        await owned(session) {
            if edit {
                var record = session.record; record.editProposal = proposal
                guard await self.persist(record, in: session) else { return }
            }
            success = await self.startDecision(.cancel, in: session)
        }
        return success
    }
    public func retry() async {
        guard canRetry, let session else { return }
        await owned(session) {
            if session.record.refreshNeeded { await self.reconcile(session); return }
            guard var request = session.record.request else { return }
            if request.negotiationInferred {
                // Legacy checkpoints may be imported offline and have no original HTTP headers.
                // Resolve only that missing metadata on explicit retry, never rewrite AG-UI input.
                var resolved = self.negotiation
                if session.proposal?.kind == .logSessions {
                    resolved.linked = true; resolved.batchSessions = true
                    if session.proposal?.metadata["proposalVersion"] == .number(3) { resolved.beginCorrection = true }
                }
                guard self.negotiation.supports(resolved) else {
                    self.setError("Update the app or reconnect a compatible service to retry this saved request.", in: session); return
                }
                let original = request
                let frozen = AssistantRequest(kind: request.kind, input: request.input, negotiation: resolved)
                do {
                    let saved = try await self.store.update(session.threadId) { record in
                        guard record.request == original else { throw AssistantStorageError.staleWrite }
                        record.request = frozen
                    }
                    self.publish(saved, in: session); request = frozen
                } catch { self.showStorageError(error); return }
            }
            guard self.negotiation.supports(request.negotiation),
                  request.input.messages.count <= self.maximumMessages,
                  (try? JSONEncoder().encode(request.input).count).map({ $0 <= self.maximumRequestBytes }) == true else {
                self.setError("Update the app or reconnect a compatible service to retry this saved request.", in: session); return
            }
            guard await self.ready() else { return }
            await self.deliver(request, in: session)
        }
    }
    private func owned(_ session: AssistantSession, action: @escaping @MainActor () async -> Void) async {
        guard !isBusy, !invalidated else { return }
        isBusy = true; session.isBusy = true
        let task = Task { await action() }
        activeTask = task
        await task.value
        session.isBusy = false; isBusy = false; activeTask = nil
    }
    private func ready() async -> Bool {
        guard !invalidated, !Task.isCancelled, networkProblem == nil else { return false }
        guard await prepareSend() else {
            if let session { setError("Synchronize pending practice changes before using the assistant.", in: session) }
            return false
        }
        return !invalidated && !Task.isCancelled && networkProblem == nil
    }
    private func startOrdinary(in session: AssistantSession) async {
        guard await ready(), await flushDraft() else { return }
        let text = session.composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            guard text.utf16.count <= 16_000 else { throw AGUIError.unavailable("The message is too long. Shorten it to 16,000 characters before sending.") }
            var record = session.record
            let message = AGUI.Message(role: "user", content: text)
            record.transcript.append(message)
            var messages = Array(record.transcript.filter { $0.content.utf16.count <= 16_000 }.suffix(maximumMessages))
            let run = UUID()
            var input: AGUI.RunAgentInput
            while true {
                input = .init(threadId: record.id, runId: run, parentRunId: record.lastCompletedRunId,
                              messages: messages, tools: AGUI.Tool.supportedFrontendTools)
                if try JSONEncoder().encode(input).count <= maximumRequestBytes { break }
                guard messages.count > 1 else { throw AGUIError.unavailable("The message is too large to send. Shorten it and try again.") }
                messages.removeFirst()
            }
            let request = AssistantRequest(kind: .ordinary, input: input, negotiation: negotiation)
            record.request = request; record.draft = ""; record.errorMessage = nil; record.activityAt = clock()
            guard await persist(record, in: session) else { return }
            session.composer = ""; draftGeneration += 1
            await deliver(request, in: session)
        } catch { setError(Self.message(error), in: session) }
    }
    private func startDecision(_ kind: AssistantRequest.Kind, in session: AssistantSession) async -> Bool {
        guard await ready(), await flushDraft(), let proposal = session.proposal else { return false }
        var record = session.record
        let confirmation = record.confirmationId ?? UUID()
        let resume: AGUI.Resume
        if kind == .confirm {
            guard proposal.canConfirm, !session.proposalExpired(at: clock()) else { return false }
            record.confirmationId = confirmation
            resume = .init(interruptId: proposal.id, status: "resolved", payload: .object([
                "decision": .string("confirm"), "confirmationId": .string(confirmation.uuidString)]))
        } else { resume = .init(interruptId: proposal.id, status: "cancelled") }
        let input = AGUI.RunAgentInput(threadId: record.id, runId: UUID(), parentRunId: record.lastCompletedRunId,
                                      messages: [], tools: AGUI.Tool.supportedFrontendTools, resume: [resume])
        guard (try? JSONEncoder().encode(input).count).map({ $0 <= maximumRequestBytes }) == true else {
            setError("This service's request limit is too small to submit the decision. Reconnect a compatible service.", in: session)
            return false
        }
        let request = AssistantRequest(kind: kind, input: input, negotiation: negotiation)
        record.request = request; record.errorMessage = nil
        guard await persist(record, in: session) else { return false }
        await deliver(request, in: session)
        return session.record.request == nil && session.record.proposal == nil
            && session.record.lastCompletedRunId == input.runId && !session.record.refreshNeeded
    }
    private func deliver(_ request: AssistantRequest, in session: AssistantSession) async {
        let binding = generation
        let client = makeClient(request.negotiation)
        do {
            var accumulator = AGUIRunAccumulator(threadId: session.threadId, runId: request.input.runId)
            for try await event in client.run(request.input) {
                try Task.checkCancellation()
                try accumulator.receive(event)
            }
            try accumulator.finish()
            let messages = accumulator.messages, proposal = accumulator.proposal
            let needsRefresh = request.kind == .confirm || accumulator.completedTools.contains(where: { $0.name == "refresh_practice" })
            let now = clock()
            let saved = try await store.update(session.threadId) { record in
                guard record.request == request else { throw AssistantStorageError.staleWrite }
                for message in messages {
                    if let previous = record.transcript.first(where: { $0.id == message.id }) {
                        guard previous.role == "assistant", previous.content == message.text else {
                            throw AGUIError.protocolViolation("Conflicting saved message identity")
                        }
                    } else { record.transcript.append(.init(id: message.id, role: "assistant", content: message.text)) }
                }
                record.proposal = proposal; record.request = nil; record.confirmationId = nil
                record.lastCompletedRunId = request.input.runId; record.activityAt = now; record.errorMessage = nil
                record.refreshNeeded = needsRefresh
                if request.kind == .cancel, let correction = record.queuedCorrection { record.draft = correction; record.queuedCorrection = nil }
                if request.kind != .cancel { record.editProposal = nil }
            }
            publish(saved, in: session)
            if request.kind == .cancel { session.composer = saved.draft }
            guard binding == generation, !invalidated else { return }
            if saved.refreshNeeded { await reconcile(session) }
            guard binding == generation, !invalidated, session.threadId == self.session?.threadId else { return }
            // Replay-safe refresh is separate from navigation, which is never replayed on launch.
            pendingNavigation = accumulator.completedTools.first { $0.name != "refresh_practice" }
        } catch {
            if error is AssistantStorageError { showStorageError(error) }
            else { await settle(error, request: request, session: session) }
        }
    }
    private func reconcile(_ session: AssistantSession) async {
        let binding = generation
        guard !invalidated, networkProblem == nil else { return }
        let succeeded = await refresh()
        guard binding == generation, !invalidated else { return }
        do {
            let saved = try await store.update(session.threadId) { record in
                if succeeded {
                    record.refreshNeeded = false
                    if record.errorMessage == "Saved, but the practice could not be refreshed. Retry when connected." { record.errorMessage = nil }
                } else { record.errorMessage = "Saved, but the practice could not be refreshed. Retry when connected." }
            }
            publish(saved, in: session)
        } catch { showStorageError(error) }
    }
    private func settle(_ error: any Error, request: AssistantRequest, session: AssistantSession) async {
        let message = Self.message(error)
        let code: String? = { if case AGUIError.server(let code, _) = error { return code }; return nil }()
        do {
            let saved = try await store.update(session.threadId) { record in
                guard record.request == request else { throw AssistantStorageError.staleWrite }
                record.errorMessage = message
                if let code {
                    if ["PROPOSAL_EXPIRED", "PROPOSAL_REJECTED", "PROPOSAL_STALE"].contains(code) {
                        record.request = nil; record.proposal = nil; record.confirmationId = nil; record.queuedCorrection = nil; record.editProposal = nil
                    } else if ["PROPOSAL_NOT_FOUND", "PROPOSAL_ALREADY_RESOLVED"].contains(code), request.kind != .ordinary {
                        record.request = nil; record.proposal = nil; record.confirmationId = nil
                        record.queuedCorrection = nil; record.editProposal = nil; record.refreshNeeded = true
                        record.errorMessage = "The saved decision could not be matched to a pending proposal. Check the refreshed practice before asking again."
                    } else if request.kind == .ordinary, ["ASSISTANT_COULD_NOT_INTERPRET", "AGUI_PROTOCOL_ERROR"].contains(code) {
                        record.request = nil; record.draft = request.input.messages.last?.content ?? record.draft
                    }
                }
            }
            publish(saved, in: session)
            if saved.request == nil {
                session.composer = saved.draft
                if saved.refreshNeeded, !invalidated { await reconcile(session) }
            }
        } catch { showStorageError(error) }
    }
    private func publish(_ saved: AssistantConversationRecord, in session: AssistantSession) {
        if session.record.revision <= saved.revision { session.record = saved }
        updateSummary(saved)
    }
    @discardableResult
    private func persist(_ record: AssistantConversationRecord, in session: AssistantSession) async -> Bool {
        do {
            let saved = try await store.save(record)
            publish(saved, in: session)
            return true
        } catch { showStorageError(error); return false }
    }
    private func setError(_ message: String, in session: AssistantSession) { session.record.errorMessage = message }
    private func showStorageError(_ error: any Error) { storageProblem = (error as? AssistantStorageError)?.localizedDescription ?? AssistantStorageError.writeFailed.localizedDescription }
    private static func message(_ error: any Error) -> String {
        switch error {
        case AGUIError.server(_, let message), AGUIError.unavailable(let message): message
        case is AssistantStorageError: AssistantStorageError.writeFailed.localizedDescription
        default: "The assistant connection was interrupted. Open this conversation and retry the saved request."
        }
    }
}
