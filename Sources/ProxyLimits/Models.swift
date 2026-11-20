import Foundation

/// One rate-limit window of one account, as the hub last saw it.
public struct LimitWindow: Equatable, Sendable, Identifiable {
    /// Stable across accounts of a provider, so windows can be pooled: "5h", "7d", "7d_sonnet".
    public let id: String
    public let label: String
    /// Share of the window already used when it was observed, 0...1.
    public let usedFraction: Double
    public let resetsAt: Date?

    public init(id: String, label: String, usedFraction: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedFraction = min(1, max(0, usedFraction))
        self.resetsAt = resetsAt
    }

    /// Share still available at `now`. A window whose reset time has passed is full again:
    /// the hub only learns about usage from traffic, so an idle account keeps its old reading.
    public func remainingFraction(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 1 }
        return 1 - usedFraction
    }

    /// The reset time if it is still ahead of `now`.
    public func upcomingReset(at now: Date) -> Date? {
        guard let resetsAt, resetsAt > now else { return nil }
        return resetsAt
    }
}

public enum Provider: String, Sendable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One signed-in account on the hub.
public struct Account: Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: Provider
    /// Email when the hub knows it, otherwise the auth file's label or name.
    public let name: String
    public let plan: String?
    /// Benched by the owner (`"disabled": true` in its auth file). Left out of pooled numbers.
    public let isDisabled: Bool
    /// The hub is not routing to it right now, for example while it cools down after a 429.
    public let isUnavailable: Bool
    public let availableAgainAt: Date?
    /// When the hub last read limits for this account. Nil until it has served a request.
    public let observedAt: Date?
    public let windows: [LimitWindow]

    public init(
        id: String,
        provider: Provider,
        name: String,
        plan: String? = nil,
        isDisabled: Bool = false,
        isUnavailable: Bool = false,
        availableAgainAt: Date? = nil,
        observedAt: Date? = nil,
        windows: [LimitWindow] = []
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.plan = plan
        self.isDisabled = isDisabled
        self.isUnavailable = isUnavailable
        self.availableAgainAt = availableAgainAt
        self.observedAt = observedAt
        self.windows = windows
    }
}
