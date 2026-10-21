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
    func testBeginCorrectionHeaderRequiresBatchAndInstance() throws {
        let url = URL(string: "http://localhost:8080")!, instance = UUID()
        let input = AGUI.RunAgentInput(threadId: UUID(), runId: UUID(), messages: [.init(role: "user", content: "Record daily")], tools: [])
        let request = try AGUIClient(baseURL: url, linkedServiceInstance: instance, batchSessions: true, beginCorrection: true).makeRequest(input)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sankalpa-Assistant-Begin-Correction"), "1")
        XCTAssertNil(try AGUIClient(baseURL: url, linkedServiceInstance: instance, beginCorrection: true).makeRequest(input).value(forHTTPHeaderField: "X-Sankalpa-Assistant-Begin-Correction"))
        XCTAssertNil(try AGUIClient(baseURL: url, batchSessions: true, beginCorrection: true).makeRequest(input).value(forHTTPHeaderField: "X-Sankalpa-Assistant-Begin-Correction"))
    }
    func testRepairPreviewAndSuggestedTimeSurviveRecoveryButMissingDetailsAreRejected() throws {
        var batch: [String: JSONValue] = [
            "entries": .array([.object(["sessionId": .string(UUID().uuidString), "occurredAt": .string("2026-09-14T00:01:00")])]),
            "skippedDays": .array([]), "repeatWarnings": .array([]), "requestedCount": .number(1),
            "plan": .object([:]), "timezone": .string("America/Chicago"),
            "beginAdjustment": .object(["id": .string(UUID().uuidString), "previousEffectiveAt": .string("2026-10-17T18:08:54"), "correctedEffectiveAt": .string("2026-09-14T00:01:00")])
        ]
        func preview(_ batch: [String: JSONValue]) throws -> AssistantProposal? {
            try AssistantProposal(outcome: .object(["type": .string("interrupt"), "interrupts": .array([.object([
                "id": .string(UUID().uuidString), "expiresAt": .string("2026-10-17T23:00:00Z"),
                "metadata": .object(["proposalType": .string("LOG_SESSIONS"), "proposalVersion": .number(3),
                                     "sankalpaId": .string(UUID().uuidString), "sankalpaTitle": .string("Observance"), "batch": .object(batch)])
            ])])]))
        }
        let proposal = try XCTUnwrap(preview(batch))
        XCTAssertTrue(proposal.canConfirm)
        XCTAssertEqual(try JSONDecoder().decode(AssistantProposal.self, from: JSONEncoder().encode(proposal)), proposal)
        batch.removeValue(forKey: "beginAdjustment")
        XCTAssertThrowsError(try preview(batch))
        batch["plan"] = .object(["recordingTimeSuggested": .bool(true)])
        XCTAssertTrue(try XCTUnwrap(preview(batch)).canConfirm)
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
