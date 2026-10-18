import XCTest
@testable import SankalpaConversation

final class BatchContractTests: XCTestCase {
    func testVersionHeaderRequiresNegotiatedSupportAndServiceIdentity() throws {
        let instance = UUID(), url = URL(string: "http://localhost:8080")!
        let input = AGUI.RunAgentInput(threadId: UUID(), runId: UUID(), messages: [.init(role: "user", content: "Record daily")], tools: [])
        let supported = AGUIClient(baseURL: url, linkedServiceInstance: instance, batchSessions: true)
        let request = try supported.makeRequest(input)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sankalpa-Assistant-Batch-Sessions"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sankalpa-Service-Instance"), instance.uuidString)
        XCTAssertNil(try AGUIClient(baseURL: url, batchSessions: true).makeRequest(input).value(forHTTPHeaderField: "X-Sankalpa-Assistant-Batch-Sessions"))
        XCTAssertNil(try AGUIClient(baseURL: url, linkedServiceInstance: instance).makeRequest(input).value(forHTTPHeaderField: "X-Sankalpa-Assistant-Batch-Sessions"))
    }
    func testMalformedBatchPreviewCannotOfferConfirmation() throws {
        let malformed: JSONValue = .object(["type": .string("interrupt"), "interrupts": .array([.object([
            "id": .string(UUID().uuidString), "expiresAt": .string("2026-10-17T20:00:00Z"),
            "metadata": .object(["proposalType": .string("LOG_SESSIONS"), "proposalVersion": .number(2), "batch": .object([:])])
        ])])])
        XCTAssertThrowsError(try AssistantProposal(outcome: malformed))
    }
    func testPersistedPreviewCannotBypassWireValidation() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"LOG_SESSIONS","expiresAt":"2026-10-17T20:00:00Z","metadata":{"proposalType":"LOG_SESSIONS","proposalVersion":2}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AssistantProposal.self, from: Data(json.utf8)))
    }
}
