import Foundation
import Testing

@testable import ProxyLimits

/// 2026-11-20 02:25:09 UTC, after every reading in the fixture.
let fixtureNow = Date(timeIntervalSince1970: 1_795_141_509)

func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "auth-files", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureAccounts() throws -> [Account] {
    try JSONDecoder().decode(AuthFilesResponse.self, from: fixtureData()).accounts
}

/// Answers every request of a `URLSession` with one canned response and records the request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status = 200
        var body = Data()
        var failure: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]

    /// A session whose requests to `host` get `stub`. Each test uses its own host so tests can
    /// run in parallel.
    static func session(host: String, stub: Stub) -> URLSession {
        lock.withLock { stubs[host] = stub }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func request(to host: String) -> URLRequest? {
        lock.withLock { requests[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let stub = Self.lock.withLock {
            Self.requests[host] = request
            return Self.stubs[host] ?? Stub()
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func client(host: String, _ stub: StubProtocol.Stub) -> HubClient {
    HubClient(
        baseURL: URL(string: "https://\(host):8317")!,
        managementKey: "test-key",
        session: StubProtocol.session(host: host, stub: stub)
    )
}

@Suite struct HubClientTests {
    @Test func readsAccountsWithTheManagementKey() async throws {
        let accounts = try await client(host: "ok.test", .init(body: fixtureData())).fetchAccounts()

        let request = try #require(StubProtocol.request(to: "ok.test"))
        #expect(request.url?.absoluteString == "https://ok.test:8317/v0/management/auth-files")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        // Five Claude entries and one Codex entry; the Gemini one has no limit reader.
        #expect(accounts.map(\.provider) == [.claude, .claude, .claude, .claude, .claude, .codex])
    }

    @Test func skipsAnEntryItCannotReadAndKeepsTheRest() async throws {
        let body = Data(
            #"""
            {"files": [
              {"id": 7, "provider": "claude"},
              {"id": "claude-ok.json", "provider": "claude", "email": "ok@example.com", "disabled": "no"},
              {"id": "claude-good.json", "provider": "Claude", "email": "good@example.com"}
            ]}
            """#.utf8)
        let accounts = try await client(host: "odd.test", .init(body: body)).fetchAccounts()
        #expect(accounts.map(\.name) == ["good@example.com"])
    }

    @Test func reportsARejectedKey() async {
        let error = await #expect(throws: HubError.self) {
            try await client(host: "unauthorized.test", .init(status: 401, body: Data(#"{"error":"invalid management key"}"#.utf8)))
                .fetchAccounts()
        }
        #expect(error == .keyRejected)
    }

    @Test func aRefusalCarriesTheHubsReason() async {
        let body = Data(#"{"error":"IP banned due to too many failed attempts. Try again in 29m0s"}"#.utf8)
        let error = await #expect(throws: HubError.self) {
            try await client(host: "banned.test", .init(status: 403, body: body)).fetchAccounts()
        }
        #expect(error == .refused("IP banned due to too many failed attempts. Try again in 29m0s"))
    }

    @Test func reportsOtherFailures() async {
        let serverError = await #expect(throws: HubError.self) {
            try await client(host: "broken.test", .init(status: 502)).fetchAccounts()
        }
        #expect(serverError == .http(502))

        let garbage = await #expect(throws: HubError.self) {
            try await client(host: "garbage.test", .init(body: Data("<html>".utf8))).fetchAccounts()
        }
        #expect(garbage == .unreadable)

        let offline = await #expect(throws: HubError.self) {
            try await client(host: "offline.test", .init(failure: URLError(.cannotConnectToHost))).fetchAccounts()
        }
        guard case .unreachable = offline else {
            Issue.record("expected .unreachable, got \(String(describing: offline))")
            return
        }
    }

    @Test(arguments: [
        ("https://hub.example.ts.net:8317", "https://hub.example.ts.net:8317"),
        ("https://hub.example.ts.net:8317/", "https://hub.example.ts.net:8317"),
        ("https://hub.example.ts.net:8317/management.html#/quota", "https://hub.example.ts.net:8317"),
        ("  http://127.0.0.1:8317/v1  ", "http://127.0.0.1:8317"),
        ("127.0.0.1:8317", "http://127.0.0.1:8317"),
        ("localhost:8317", "http://localhost:8317"),
        // No scheme on a remote host means HTTPS: the request carries the management key.
        ("hub.example.ts.net:8317", "https://hub.example.ts.net:8317"),
        ("localhost.example.com:8317", "https://localhost.example.com:8317"),
        ("127.0.0.1.example.com", "https://127.0.0.1.example.com"),
    ])
    func normalizesPastedAddresses(input: String, expected: String) {
        #expect(HubClient.normalizedBaseURL(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://hub.example:8317", "https://"])
    func rejectsNonHubAddresses(input: String) {
        #expect(HubClient.normalizedBaseURL(input) == nil)
    }

    @Test(arguments: [
        ("2026-11-19T20:05:09.482913-05:00", 1_795_136_709.482),
        ("2026-11-19T18:40:00Z", 1_795_113_600),
        ("2026-11-19T23:50:00.5Z", 1_795_132_200.5),
        ("2026-11-19T23:50:00.123456789Z", 1_795_132_200.123),
    ])
    func parsesGoTimestamps(text: String, expected: Double) throws {
        let date = try #require(Timestamp.parse(text))
        #expect(abs(date.timeIntervalSince1970 - expected) < 0.001)
    }
}
