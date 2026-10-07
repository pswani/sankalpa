import XCTest
@testable import SankalpaConversation

final class AGUIProtocolTests: XCTestCase {
    func testPinnedGoldenTextStreamFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "text-stream", withExtension: "sse"))
        let data = try Data(contentsOf: url)
        var decoder = SSEDecoder()
        let events = try decoder.append(data) + decoder.finish()
        var accumulator = AGUIRunAccumulator(
            threadId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            runId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        for event in events { try accumulator.receive(event) }
        try accumulator.finish()
        XCTAssertEqual(accumulator.messages.map(\.text), ["Hello."])
    }

    func testPinnedConfirmationRequestFixtureDecodesExactly() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "confirmation-request", withExtension: "json"))
        let input = try JSONDecoder().decode(AGUI.RunAgentInput.self, from: Data(contentsOf: url))
        XCTAssertEqual(input.resume?.first?.status, "resolved")
        XCTAssertEqual(input.messages, [])
        XCTAssertEqual(input.state, [:])
        XCTAssertEqual(input.context, [])
    }

    func testFragmentedSSEDecodesAndReassemblesMessage() throws {
        let thread = UUID(), run = UUID(), message = UUID()
        let frames = [
            json("RUN_STARTED", thread, run, ""),
            json("TEXT_MESSAGE_START", thread, run, ",\"messageId\":\"\(message)\",\"role\":\"assistant\""),
            json("TEXT_MESSAGE_CONTENT", thread, run, ",\"messageId\":\"\(message)\",\"delta\":\"Hello \""),
            json("TEXT_MESSAGE_CONTENT", thread, run, ",\"messageId\":\"\(message)\",\"delta\":\"there\""),
            json("TEXT_MESSAGE_END", thread, run, ",\"messageId\":\"\(message)\""),
            json("RUN_FINISHED", thread, run, ",\"outcome\":{\"type\":\"success\"}")
        ].joined()
        var decoder = SSEDecoder(), events: [AGUI.Event] = []
        for byte in frames.utf8 { events += try decoder.append(Data([byte])) }
        _ = try decoder.finish()
        var accumulator = AGUIRunAccumulator(threadId: thread, runId: run)
        for event in events { try accumulator.receive(event) }
        try accumulator.finish()
        XCTAssertEqual(accumulator.messages.map(\.text), ["Hello there"])
    }

    func testToolDoesNotCompleteUntilEndAndUnknownToolFailsClosed() throws {
        let thread = UUID(), run = UUID(), tool = UUID()
        var accumulator = AGUIRunAccumulator(threadId: thread, runId: run)
        try accumulator.receive(.runStarted(threadId: thread, runId: run))
        try accumulator.receive(.toolStart(threadId: thread, runId: run, toolCallId: tool, name: "refresh_practice"))
        try accumulator.receive(.toolArgs(threadId: thread, runId: run, toolCallId: tool, delta: "{\"reason\":\"SESSION_LOGGED\"}"))
        XCTAssertTrue(accumulator.completedTools.isEmpty)
        try accumulator.receive(.toolEnd(threadId: thread, runId: run, toolCallId: tool))
        XCTAssertEqual(accumulator.completedTools.count, 1)

        var unsafe = AGUIRunAccumulator(threadId: thread, runId: UUID())
        let unsafeRun = UUID(); unsafe = AGUIRunAccumulator(threadId: thread, runId: unsafeRun)
        try unsafe.receive(.runStarted(threadId: thread, runId: unsafeRun))
        try unsafe.receive(.toolStart(threadId: thread, runId: unsafeRun, toolCallId: tool, name: "delete_everything"))
        try unsafe.receive(.toolArgs(threadId: thread, runId: unsafeRun, toolCallId: tool, delta: "{}"))
        XCTAssertThrowsError(try unsafe.receive(.toolEnd(threadId: thread, runId: unsafeRun, toolCallId: tool)))
    }

    func testMalformedAndIncompleteStreamsFail() throws {
        var decoder = SSEDecoder()
        _ = try decoder.append(Data("data: {\"type\":\"RUN_STARTED\"}".utf8))
        XCTAssertThrowsError(try decoder.finish())

        let thread = UUID(), run = UUID()
        var accumulator = AGUIRunAccumulator(threadId: thread, runId: run)
        try accumulator.receive(.runStarted(threadId: thread, runId: run))
        XCTAssertThrowsError(try accumulator.finish())
        XCTAssertThrowsError(try accumulator.receive(.textEnd(threadId: thread, runId: run, messageId: UUID())))
    }

    func testConfirmationAndCancellationEncodeExactResumeShape() throws {
        let proposal = UUID(), confirmation = UUID(), thread = UUID()
        let confirm = AGUI.RunAgentInput(threadId: thread, runId: UUID(), messages: [],
            tools: [.refreshPractice], resume: [.init(interruptId: proposal, status: "resolved",
                payload: .object(["decision": .string("confirm"), "confirmationId": .string(confirmation.uuidString)]))])
        let cancel = AGUI.RunAgentInput(threadId: thread, runId: UUID(), messages: [], tools: [],
            resume: [.init(interruptId: proposal, status: "cancelled")])
        let encoder = JSONEncoder(); let confirmed = String(data: try encoder.encode(confirm), encoding: .utf8)!
        let cancelled = String(data: try encoder.encode(cancel), encoding: .utf8)!
        XCTAssertTrue(confirmed.contains("confirmationId")); XCTAssertTrue(confirmed.contains("resolved"))
        XCTAssertTrue(cancelled.contains("cancelled")); XCTAssertFalse(cancelled.contains("payload"))
    }

    private func json(_ type: String, _ thread: UUID, _ run: UUID, _ rest: String) -> String {
        "data: {\"type\":\"\(type)\",\"threadId\":\"\(thread)\",\"runId\":\"\(run)\"\(rest)}\n\n"
    }
}
