import Foundation

public enum HubError: Error, Equatable, Sendable {
    /// The hub refused the management key. Asking again with the same key is harmful:
    /// CLIProxyAPI bans an address from its management API for 30 minutes after five failed
    /// attempts.
    case keyRejected
    /// The hub answered 403: management is off, remote access is off, or this address is
    /// banned. Carries the hub's own explanation. Asking again is safe, a 403 is not counted
    /// as a failed attempt.
    case refused(String)
    case http(Int)
    case unreachable(String)
    case unreadable

    public var message: String {
        switch self {
        case .keyRejected: "The hub rejected the management key."
        case .refused(let reason): "The hub refused the request: \(reason)"
        case .http(let status): "The hub answered with HTTP \(status)."
        case .unreachable(let reason): reason
        case .unreadable: "The hub's answer was not the expected account list."
        }
    }
}

/// Reads accounts and their limits from a CLIProxyAPI hub's management API.
public struct HubClient: Sendable {
    public let baseURL: URL
    private let managementKey: String
    private let session: URLSession

    /// Keeps nothing on disk. The shared session would cache every answer in
    /// `~/Library/Caches`, and an answer lists each account's email and, for API-key
    /// credentials, the key itself.
    private static let privateSession = URLSession(configuration: .ephemeral)

    public init(baseURL: URL, managementKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.session = session ?? Self.privateSession
    }

    /// Accepts what people paste: a bare host, a trailing slash, or the panel's own address
    /// (`https://hub.example.ts.net:8317/management.html`). Returns the hub's origin.
    public static func normalizedBaseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            // Without a scheme, only this machine gets plain HTTP: the request carries the
            // management key.
            let host = URLComponents(string: "https://" + trimmed)?.host?.lowercased() ?? ""
            let isLocal = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
            trimmed = (isLocal ? "http://" : "https://") + trimmed
        }
        guard let parsed = URLComponents(string: trimmed),
            let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = parsed.host, !host.isEmpty
        else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parsed.port
        return origin.url
    }

    public func fetchAccounts() async throws(HubError) -> [Account] {
        var request = URLRequest(url: baseURL.appending(path: "v0/management/auth-files"))
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadable }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw .keyRejected
        case 403:
            throw .refused(Self.errorText(in: data) ?? "HTTP 403")
        default:
            throw .http(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(AuthFilesResponse.self, from: data) else {
            throw .unreadable
        }
        return decoded.accounts
    }

    /// The hub's `{"error": "..."}` text, kept short. Only used for 403, whose body says why
    /// management is closed and never carries account data.
    private static func errorText(in data: Data) -> String? {
        struct Body: Decodable { let error: String }
        guard let text = try? JSONDecoder().decode(Body.self, from: data).error, !text.isEmpty else {
            return nil
        }
        return String(text.prefix(160))
    }
}

/// Stops at a redirect instead of following it. The hub never answers this route with one,
/// and following it would hand the management key to wherever it points.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: Wire format

struct AuthFilesResponse: Decodable {
    private let files: [Entry]

    /// An entry in a shape the widget doesn't expect is skipped, so one odd credential can't
    /// blank every other account.
    private struct Entry: Decodable {
        let file: AuthFile?

        init(from decoder: Decoder) throws {
            file = try? AuthFile(from: decoder)
        }
    }

    var accounts: [Account] { files.compactMap { $0.file?.account } }
}

/// One entry of `GET /v0/management/auth-files`. Everything the widget doesn't need is left
/// undecoded, including `account`, which holds the raw key for API-key credentials.
struct AuthFile: Decodable {
    let id: String?
    let name: String?
    let provider: String?
    let label: String?
    let email: String?
    let disabled: Bool?
    let unavailable: Bool?
    let nextRetryAfter: String?
    let quota: Quota?

    struct Quota: Decodable {
        let observedAt: String?
        let signals: [String: String]?

        enum CodingKeys: String, CodingKey {
            case observedAt = "observed_at"
            case signals
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, label, email, disabled, unavailable, quota
        case nextRetryAfter = "next_retry_after"
    }

    /// Nil for providers the widget has no limit reader for.
    var account: Account? {
        guard let provider = provider.flatMap({ Provider(rawValue: $0.lowercased()) }),
            let id = id ?? name
        else { return nil }
        let observedAt = quota?.observedAt.flatMap(Timestamp.parse)
        let signals = quota?.signals ?? [:]
        let displayName = [email, label, name].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return Account(
            id: id,
            provider: provider,
            name: displayName ?? id,
            plan: signals.first { $0.key.lowercased() == "x-codex-plan-type" }?.value,
            isDisabled: disabled ?? false,
            isUnavailable: unavailable ?? false,
            availableAgainAt: nextRetryAfter.flatMap(Timestamp.parse),
            observedAt: observedAt,
            windows: SignalParser.windows(provider: provider, signals: signals, observedAt: observedAt)
        )
    }
}

enum Timestamp {
    /// Parses the hub's Go timestamps: RFC 3339 with up to nine fractional digits.
    static func parse(_ text: String) -> Date? {
        // ISO8601DateFormatter reads milliseconds at most, so drop any finer digits.
        let trimmed = text.replacing(/(\.\d{3})\d+/) { $0.1 }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: String(trimmed)) { return date }
        return ISO8601DateFormatter().date(from: String(trimmed))
    }
}
