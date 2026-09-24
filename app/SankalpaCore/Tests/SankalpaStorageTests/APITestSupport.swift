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
    private var routes: [String: (URLRequest) -> (status: Int, body: String)] = [:]
    private var asyncRoutes: [String: (URLRequest) async throws -> (status: Int, body: String)] = [:]
    private var recorded: [String] = []
    private var recordedRequests: [URLRequest] = []
    private var failure: URLError?

    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var sentRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    func on(_ method: String, _ path: String, status: Int = 200, body: String) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = { _ in (status, body) }
    }

    func on(
        _ method: String, _ path: String,
        response: @escaping (URLRequest) -> (status: Int, body: String)
    ) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = response
    }

    func onAsync(
        _ method: String, _ path: String,
        response: @escaping (URLRequest) async throws -> (status: Int, body: String)
    ) {
        lock.lock(); defer { lock.unlock() }
        asyncRoutes["\(method) \(path)"] = response
    }

    /// Makes every request fail the way an unreachable service does.
    func failEverything(with error: URLError) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = (request.url?.path ?? "")
            + (request.url?.query.map { "?\($0)" } ?? "")
        let key = "\(request.httpMethod ?? "GET") \(path)"

        let (failure, handler, asyncHandler) = lock.withLock {
            recorded.append(key)
            recordedRequests.append(request)
            // A query string is part of the identity of a session page, but a test that does not
            // care about paging should not have to spell one out.
            let fallback = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
            return (
                self.failure,
                routes[key] ?? routes[fallback],
                asyncRoutes[key] ?? asyncRoutes[fallback]
            )
        }

        if let failure { throw failure }
        let match: (status: Int, body: String)
        if let asyncHandler {
            match = try await asyncHandler(request)
        } else if let handler {
            match = handler(request)
        } else {
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

/// Suspends one stubbed request until a test has completed the operation intended to race it.
actor RequestGate {
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendRequest() async {
        reached = true
        let waiters = reachedWaiters
        reachedWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
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
    static let serviceInstanceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

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
        total: Int? = nil,
        page: Int = 0,
        totalPages: Int = 1,
        ids: [String]? = nil
    ) -> String {
        let rows = occurrences.enumerated().map { index, at in
            let id = ids.flatMap { index < $0.count ? $0[index] : nil } ?? UUID().uuidString
            return """
            {"id":"\(id)","sankalpaId":"\(sankalpaId)",
             "occurredAt":"\(at)","loggedAt":"\(at)"}
            """
        }
        let count = total ?? occurrences.count
        return """
        {"content":[\(rows.joined(separator: ","))],"page":\(page),"size":200,
         "totalElements":\(count),"totalPages":\(totalPages)}
        """
    }

    static func problemJSON(code: String, detail: String, status: Int = 422) -> String {
        """
        {"type":"urn:sankalpa:problem:\(code.lowercased())","title":"Unprocessable Entity",
         "status":\(status),"detail":"\(detail)","code":"\(code)"}
        """
    }

    static func acceptsLoggedSession(
        on transport: StubTransport, status: Int = 201,
        loggedAt: String = "2026-09-10T12:00:00"
    ) {
        transport.on("POST", "/api/v1/sankalpas/\(sankalpaId)/sessions") { request in
            let object = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [String: Any]
            let id = object?["id"] as? String ?? sessionId
            let occurredAt = object?["occurredAt"] as? String ?? "2026-09-10T07:00:00"
            return (status, """
                {"id":"\(id)","sankalpaId":"\(sankalpaId)",
                 "occurredAt":"\(occurredAt)","loggedAt":"\(loggedAt)"}
                """)
        }
    }

    /// A transport already answering everything one in-progress sankalpa needs.
    static func readyTransport() -> StubTransport {
        let transport = StubTransport()
        transport.on("GET", "/api/v1/capabilities", body: """
            {"sessionCommandIdentity":1,"serviceInstanceId":"\(serviceInstanceId)"}
            """)
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

func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
    guard let value = CalendarDay(year: year, month: month, day: dayOfMonth) else {
        fatalError("invalid test date")
    }
    return value
}
