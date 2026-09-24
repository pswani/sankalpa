import Foundation
import SankalpaCore

/// One HTTP exchange. A protocol so tests can answer requests without a server, and so the client
/// itself holds no `URLSession` knowledge.
public protocol APITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: APITransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIFailure.unreachable("The service gave an unexpected response.")
        }
        return (data, http)
    }
}

/// Why a call did not produce a result.
///
/// `refused` is the service applying a rule and is mapped back into the app's own domain errors by
/// `ServerRefusal`. Everything else is the call not arriving or not being understood, which the
/// app reports as the connection problem it is.
public enum APIFailure: Error, Sendable {
    /// The service applied a rule. Carries its stable `code` and its own explanatory `detail`.
    case refused(code: String, detail: String, status: Int)
    /// The request never completed, or came back as something other than a documented response.
    case unreachable(String)

    public var fallbackMessage: String {
        switch self {
        case .refused(_, let detail, _): return detail
        case .unreachable(let message): return message
        }
    }
}

/// The driven adapter for the Sankalpa REST API.
///
/// It speaks HTTP and nothing else: no caching, no domain rules, no retries. Every method maps one
/// endpoint, returns the decoded DTO, and turns a non-2xx into `APIFailure.refused` carrying the
/// service's stable problem `code`.
public struct SankalpaAPIClient: Sendable {
    private let baseURL: URL
    private let transport: APITransport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL, transport: APITransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `http://localhost:8080`, the service's default, for a simulator talking to a Mac.
    public static let defaultBaseURL = URL(string: "http://localhost:8080")!

    // MARK: - Commands

    func declare(_ declaration: Declaration) async throws -> API.SankalpaResponse {
        try await send(
            "POST", "/api/v1/sankalpas",
            body: APIMapping.declareRequest(declaration),
            as: API.SankalpaResponse.self
        )
    }

    func begin(_ id: SankalpaId, effectiveAt: CalendarMoment?) async throws -> API.SankalpaResponse {
        try await send(
            "POST", "/api/v1/sankalpas/\(id.value.uuidString)/begin",
            body: API.BeginRequest(effectiveAt: effectiveAt.map(WireFormat.text)),
            as: API.SankalpaResponse.self
        )
    }

    func pause(_ id: SankalpaId) async throws -> API.SankalpaResponse {
        try await send("POST", "/api/v1/sankalpas/\(id.value.uuidString)/pause",
                       body: Empty?.none, as: API.SankalpaResponse.self)
    }

    func resume(_ id: SankalpaId) async throws -> API.SankalpaResponse {
        try await send("POST", "/api/v1/sankalpas/\(id.value.uuidString)/resume",
                       body: Empty?.none, as: API.SankalpaResponse.self)
    }

    func complete(
        _ id: SankalpaId, outcome: CompletionOutcome
    ) async throws -> API.SankalpaResponse {
        try await send(
            "POST", "/api/v1/sankalpas/\(id.value.uuidString)/complete",
            body: API.CompleteRequest(outcome: APIEnum.wire(outcome)),
            as: API.SankalpaResponse.self
        )
    }

    func stop(_ id: SankalpaId) async throws -> API.SankalpaResponse {
        try await send("POST", "/api/v1/sankalpas/\(id.value.uuidString)/stop",
                       body: Empty?.none, as: API.SankalpaResponse.self)
    }

    func logSession(
        _ id: SankalpaId, sessionId: SessionId, occurredAt: CalendarMoment,
        serviceInstanceId: UUID
    ) async throws -> API.SessionResponse {
        try await send(
            "POST", "/api/v1/sankalpas/\(id.value.uuidString)/sessions",
            body: API.LogSessionRequest(id: sessionId.value, occurredAt: WireFormat.text(occurredAt)),
            headers: [
                "Idempotency-Key": sessionId.value.uuidString,
                "Sankalpa-Service-Instance": serviceInstanceId.uuidString
            ],
            as: API.SessionResponse.self
        )
    }

    func deleteSession(
        _ id: SankalpaId, sessionId: SessionId, serviceInstanceId: UUID
    ) async throws {
        try await sendWithoutResponse(
            "DELETE", "/api/v1/sankalpas/\(id.value.uuidString)/sessions/\(sessionId.value.uuidString)",
            headers: ["Sankalpa-Service-Instance": serviceInstanceId.uuidString]
        )
    }

    // MARK: - Queries

    func capabilities() async throws -> API.CapabilitiesResponse {
        try await send("GET", "/api/v1/capabilities", body: Empty?.none,
                       as: API.CapabilitiesResponse.self)
    }

    func list() async throws -> [API.SankalpaResponse] {
        try await send("GET", "/api/v1/sankalpas", body: Empty?.none, as: [API.SankalpaResponse].self)
    }

    func lifecycleHistory(
        _ id: SankalpaId
    ) async throws -> [API.LifecycleTransitionResponse] {
        try await send(
            "GET", "/api/v1/sankalpas/\(id.value.uuidString)/lifecycle-history",
            body: Empty?.none, as: [API.LifecycleTransitionResponse].self
        )
    }

    func sessionPage(
        _ id: SankalpaId, page: Int, size: Int
    ) async throws -> API.SessionPageResponse {
        try await send(
            "GET", "/api/v1/sankalpas/\(id.value.uuidString)/sessions?page=\(page)&size=\(size)",
            body: Empty?.none, as: API.SessionPageResponse.self
        )
    }

    // MARK: - Plumbing

    private struct Empty: Encodable {}

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Body?,
        headers: [String: String] = [:],
        as type: Response.Type
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIFailure.unreachable("The service address is not usable.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw APIFailure.unreachable("The request could not be prepared.")
            }
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let failure as APIFailure {
            throw failure
        } catch {
            throw APIFailure.unreachable(Self.connectionMessage(for: error))
        }

        guard (200...299).contains(response.statusCode) else {
            throw refusal(from: data, status: response.statusCode)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIFailure.unreachable(
                "The service sent a response this version of the app could not read."
            )
        }
    }

    private func sendWithoutResponse(
        _ method: String, _ path: String, headers: [String: String] = [:]
    ) async throws {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIFailure.unreachable("The service address is not usable.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let failure as APIFailure {
            throw failure
        } catch {
            throw APIFailure.unreachable(Self.connectionMessage(for: error))
        }
        guard (200...299).contains(response.statusCode) else {
            throw refusal(from: data, status: response.statusCode)
        }
    }

    /// A non-2xx is expected to be problem+json with a stable `code`. When it is not — a proxy
    /// error page, a 500 — there is no code to map, so it stays an unreachable-service failure.
    private func refusal(from data: Data, status: Int) -> APIFailure {
        guard let problem = try? decoder.decode(API.Problem.self, from: data),
              let code = problem.code
        else {
            return .unreachable("The service could not complete that (error \(status)).")
        }
        let detail = problem.detail ?? "The service refused that change."
        return .refused(code: code, detail: detail, status: status)
    }

    private static func connectionMessage(for error: Error) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .some(.notConnectedToInternet), .some(.networkConnectionLost):
            return "This device is not connected, so your practice could not be reached."
        case .some(.cannotConnectToHost), .some(.cannotFindHost):
            return "The Sankalpa service is not answering. Check that it is running, then try again."
        case .some(.timedOut):
            return "The Sankalpa service took too long to answer. Try again."
        default:
            return "Your practice could not be reached right now. Try again."
        }
    }
}
