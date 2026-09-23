import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

/// A transport that answers from a routing table instead of a network.
///
/// Requests are recorded so a test can assert what the app actually asked for — which is the only
/// way to catch a refresh that quietly stopped reading session history, or a command sent to the
/// wrong endpoint.
final class StubTransport: APITransport, @unchecked Sendable {
    /// `"POST /api/v1/sankalpas"` → the status and body to answer with.
    typealias Route = (path: String, method: String)

    private let lock = NSLock()
    private var routes: [String: (status: Int, body: String)] = [:]
    private var recorded: [String] = []
    private var recordedBodies: [String: [Data]] = [:]
    private var recordedHeaders: [String: [[String: String]]] = [:]
    private var failure: URLError?
    private var routeFailures: [String: URLError] = [:]

    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func bodies(for request: String) -> [Data] {
        lock.withLock { recordedBodies[request] ?? [] }
    }

    func headers(for request: String) -> [[String: String]] {
        lock.withLock { recordedHeaders[request] ?? [] }
    }

    func on(_ method: String, _ path: String, status: Int = 200, body: String) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = (status, body)
    }

    /// Makes every request fail the way an unreachable service does.
    func failEverything(with error: URLError) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }

    func fail(_ method: String, _ path: String, with error: URLError) {
        lock.lock(); defer { lock.unlock() }
        routeFailures["\(method) \(path)"] = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = (request.url?.path ?? "")
            + (request.url?.query.map { "?\($0)" } ?? "")
        let key = "\(request.httpMethod ?? "GET") \(path)"

        let (failure, match) = lock.withLock {
            recorded.append(key)
            if let body = request.httpBody {
                recordedBodies[key, default: []].append(body)
            }
            recordedHeaders[key, default: []].append(request.allHTTPHeaderFields ?? [:])
            // A query string is part of the identity of a session page, but a test that does not
            // care about paging should not have to spell one out.
            let fallback = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
            return (
                self.failure ?? routeFailures[key] ?? routeFailures[fallback],
                routes[key] ?? routes[fallback]
            )
        }

        if let failure { throw failure }
        guard let match else {
            Issue.record("no stubbed response for \(key)")
            throw URLError(.unsupportedURL)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: match.status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(match.body.utf8), response)
    }
}

/// A clock the tests hold still.
final class StubClock: SankalpaClock, @unchecked Sendable {
    let current: CalendarMoment
    init(_ current: CalendarMoment) { self.current = current }
    func now() -> CalendarMoment { current }
}

// MARK: - Fixtures

enum Fixture {
    static let sankalpaId = "11111111-1111-1111-1111-111111111111"
    static let sessionId = "22222222-2222-2222-2222-222222222222"

    static func sankalpaJSON(
        id: String = sankalpaId,
        title: String = "Vipassana",
        state: String = "IN_PROGRESS",
        startDate: String = "2026-09-01",
        endDate: String? = "2026-09-30",
        periodUnit: String = "DAY",
        timesPerPeriod: Int = 2,
        periodCount: Int? = 30,
        actionType: String = "MEDITATION"
    ) -> String {
        """
        {"id":"\(id)","title":"\(title)","description":"Sit",
         "actionType":"\(actionType)","startDate":"\(startDate)",
         "endDate":\(endDate.map { "\"\($0)\"" } ?? "null"),
         "periodUnit":"\(periodUnit)","timesPerPeriod":\(timesPerPeriod),
         "periodCount":\(periodCount.map(String.init) ?? "null"),
         "lifecycleState":"\(state)","declaredAt":"2026-09-01T06:00:00.123456"}
        """
    }

    static func transitionsJSON(
        _ entries: [(from: String, to: String, at: String)] = [
            (from: "NOT_STARTED", to: "IN_PROGRESS", at: "2026-09-01T06:00:00")
        ]
    ) -> String {
        let rows = entries.map {
            """
            {"from":"\($0.from)","to":"\($0.to)","effectiveAt":"\($0.at)","recordedAt":"\($0.at)"}
            """
        }
        return "[\(rows.joined(separator: ","))]"
    }

    static func sessionPageJSON(
        occurrences: [String] = ["2026-09-01T07:00:00"],
        ids: [String]? = nil,
        total: Int? = nil
    ) -> String {
        let rows = occurrences.enumerated().map { index, at in
            """
            {"id":"\(ids?[safe: index] ?? UUID().uuidString)","sankalpaId":"\(sankalpaId)",
             "occurredAt":"\(at)","loggedAt":"\(at)"}
            """
        }
        let count = total ?? occurrences.count
        return """
        {"content":[\(rows.joined(separator: ","))],"page":0,"size":200,
         "totalElements":\(count),"totalPages":1}
        """
    }

    static func problemJSON(code: String, detail: String, status: Int = 422) -> String {
        """
        {"type":"urn:sankalpa:problem:\(code.lowercased())","title":"Unprocessable Entity",
         "status":\(status),"detail":"\(detail)","code":"\(code)"}
        """
    }

    /// A transport already answering everything one in-progress sankalpa needs.
    static func readyTransport() -> StubTransport {
        let transport = StubTransport()
        transport.on("GET", "/api/v1/sankalpas", body: "[\(sankalpaJSON())]")
        transport.on("GET", "/api/v1/sankalpas/\(sankalpaId)/lifecycle-history",
                     body: transitionsJSON())
        transport.on("GET", "/api/v1/sankalpas/\(sankalpaId)/sessions",
                     body: sessionPageJSON())
        return transport
    }

    static let location = ServiceLocation(host: "localhost", port: 8080)

    @MainActor
    static func service(
        transport: StubTransport,
        today: CalendarMoment = CalendarMoment(day: day(2026, 9, 10), hour: 12),
        cache: PracticeCache = PracticeCache(directory: temporaryDirectory()),
        at location: ServiceLocation = Fixture.location
    ) -> RemoteSankalpaService {
        RemoteSankalpaService(
            location: location,
            clock: StubClock(today),
            cache: cache,
            transport: transport
        )
    }

    /// A directory of its own per test, so one test's cache and outbox can never be another's.
    static func temporaryDirectory() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("sankalpa-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
    guard let value = CalendarDay(year: year, month: month, day: dayOfMonth) else {
        fatalError("invalid test date")
    }
    return value
}
