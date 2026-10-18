import Foundation
import Testing
@testable import SankalpaStorage
@testable import SankalpaCore

@Suite("Cloud endpoint compatibility")
struct CloudEndpointTests {
    @Test func httpsUses443AndNormalizesDisplay() {
        let implicit = ServiceLocation(text: "https://example.lambda-url.us-east-1.on.aws/")!
        let explicit = ServiceLocation(text: "https://example.lambda-url.us-east-1.on.aws:443")!
        #expect(implicit == explicit)
        #expect(implicit.displayText == "https://example.lambda-url.us-east-1.on.aws")
        #expect(implicit.url.port == 443)
        #expect(ServiceLocation(host: "example.on.aws", scheme: "https").port == 443)
        #expect(ServiceLocation(text: "studio.local")!.port == 8080)
    }
    @Test func legacy443CacheAndJournalRetainIdentity() {
        let location = ServiceLocation(text: "https://example.on.aws")!
        let cache = PracticeCache(directory: Fixture.temporaryDirectory())
        let instance = UUID()
        let practice = CachedPractice(serviceLocation: "https://example.on.aws:443", sankalpas: [], sessions: [], serviceInstanceId: instance)
        #expect(cache.saveCache(practice))
        var journal = ReliabilityJournal(serviceLocation: "https://example.on.aws:443")
        journal.capability = ServiceCapability(sessionCommandIdentity: 1, serviceInstanceId: instance)
        #expect(cache.saveJournal(journal))
        #expect(cache.loadCache(for: location)?.serviceInstanceId == instance)
        #expect(cache.loadJournal(for: location).capability?.serviceInstanceId == instance)
        #expect(cache.loadJournal(for: location).serviceLocation == location.displayText)
        #expect(cache.loadCache(for: ServiceLocation(text: "https://other.on.aws")!) == nil)
    }
    @Test func readsRetryGatewayResponsesButDeclarationDoesNot() async throws {
        let transport = StubTransport()
        let client = SankalpaAPIClient(baseURL: URL(string: "https://example.lambda-url.us-east-1.on.aws")!, transport: transport)
        transport.on("GET", "/api/v1/capabilities", status: 429, body: "AWS throttle")
        do { _ = try await client.capabilities(); Issue.record("Expected temporary failure") } catch {}
        #expect(transport.requests.count == 3)
        #expect(transport.sentRequests.allSatisfy { $0.url?.scheme == "https" })
        transport.on("POST", "/api/v1/sankalpas", status: 503, body: "AWS unavailable")
        do {
            _ = try await client.declare(Declaration(title: "Sit", actionType: .meditation,
                startDate: day(2026, 10, 13), periodUnit: .day, timesPerPeriod: 1))
            Issue.record("Expected declaration failure")
        } catch {}
        #expect(transport.requests.filter { $0 == "POST /api/v1/sankalpas" }.count == 1)
    }
}
