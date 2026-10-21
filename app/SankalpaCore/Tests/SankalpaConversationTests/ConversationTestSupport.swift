import Foundation
import XCTest
@testable import SankalpaConversation

final class ConversationHarness: @unchecked Sendable {
    let directory: URL
    let instance: UUID
    let faults = ConversationWriteFaults()
    init(instance: UUID = UUID()) throws {
        self.instance = instance
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func store(instance: UUID? = nil) -> AssistantConversationStore {
        AssistantConversationStore(serviceInstanceId: instance ?? self.instance, assistantDirectory: directory,
            beforeWrite: { [faults] in try faults.write($0) })
    }
    @MainActor func controller(_ client: any AssistantRunClient, instance: UUID? = nil,
        negotiation: AssistantNegotiation = .init(), maxMessages: Int = 20, maxBytes: Int = 262_144,
        availability: @escaping @MainActor @Sendable () -> String? = { nil },
        prepare: @escaping @MainActor @Sendable () async -> Bool = { true },
        refresh: @escaping @MainActor @Sendable () async -> Bool = { true }) async -> AssistantConversationController {
        let controller = AssistantConversationController(store: store(instance: instance), negotiation: negotiation,
            maximumMessages: maxMessages, maximumRequestBytes: maxBytes, makeClient: { _ in client },
            availability: availability, prepareSend: prepare, refresh: refresh)
        await controller.open()
        return controller
    }
}

final class ConversationWriteFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Int?
    private var count = 0
    func arm(allow: Int = 0) { lock.withLock { allowed = allow } }
    func write(_ url: URL) throws {
        try lock.withLock {
            count += 1
            if let remaining = allowed {
                if remaining == 0 { allowed = nil; throw CocoaError(.fileWriteOutOfSpace) }
                allowed = remaining - 1
            }
        }
    }
}

@MainActor extension AssistantConversationController {
    func ask(_ text: String) async { updateDraft(text); await send() }
}

final class HeldConversationClient: AssistantRunClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AGUI.Event, Error>.Continuation?
    private var input: AGUI.RunAgentInput?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    var didStart: Bool { lock.withLock { input != nil } }
    func run(_ input: AGUI.RunAgentInput) -> AsyncThrowingStream<AGUI.Event, Error> {
        AsyncThrowingStream { continuation in
            let waiters = lock.withLock {
                self.input = input; self.continuation = continuation
                let waiters = startWaiters; startWaiters = []; return waiters
            }
            for waiter in waiters { waiter.resume() }
            continuation.yield(.runStarted(threadId: input.threadId, runId: input.runId))
        }
    }
    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if input != nil { continuation.resume() } else { startWaiters.append(continuation) }
            }
        }
    }
    func finish() {
        let pair = lock.withLock { (input, continuation) }
        guard let input = pair.0, let continuation = pair.1 else { return }
        let id = UUID()
        continuation.yield(.textStart(threadId: input.threadId, runId: input.runId, messageId: id))
        continuation.yield(.textContent(threadId: input.threadId, runId: input.runId, messageId: id, delta: "Finished"))
        continuation.yield(.textEnd(threadId: input.threadId, runId: input.runId, messageId: id))
        continuation.yield(.runFinished(threadId: input.threadId, runId: input.runId, outcome: nil))
        continuation.finish()
    }
}

/// Holds selection at the file boundary to exercise navigation/request interleaving deterministically.
final class SelectionWriteBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var armed = false
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?
    func arm() { lock.withLock { armed = true } }
    func write(_ url: URL) {
        let shouldPause = lock.withLock {
            if armed && url.lastPathComponent == "selection.json" { armed = false; return true }
            return false
        }
        guard shouldPause else { return }
        let continuation = lock.withLock { paused = true; return waiter }
        continuation?.resume()
        released.wait()
    }
    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if paused { continuation.resume() } else { waiter = continuation }
            }
        }
    }
    func release() { released.signal() }
}
