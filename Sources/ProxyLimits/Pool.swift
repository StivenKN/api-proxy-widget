import Foundation

/// One limit window averaged over a provider's accounts.
public struct PooledWindow: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// Average share still available, 0...1, over the accounts that report this window.
    public let remainingFraction: Double
    /// How many accounts report this window: the denominator of the average.
    public let accountCount: Int
    /// The soonest reset still ahead among those accounts.
    public let nextReset: Date?
}

/// A provider's accounts and their pooled limits at one moment.
public struct ProviderPool: Equatable, Sendable, Identifiable {
    public let provider: Provider
    public let accounts: [Account]
    public let windows: [PooledWindow]

    public var id: String { provider.id }

    /// Accounts that count toward the pool: everything the owner hasn't benched.
    public var activeAccountCount: Int { accounts.count { !$0.isDisabled } }

    public func window(_ id: String) -> PooledWindow? { windows.first { $0.id == id } }
}

public enum Pool {
    /// Groups accounts by provider and averages each window.
    ///
    /// An account that doesn't report a window is left out of that window's average instead of
    /// counted as full, the same rule CLIProxyAPI's management panel uses: one account at 60%
    /// reads "60% left", not a diluted 90%. Benched accounts are listed but never averaged.
    public static func pools(from accounts: [Account], at now: Date) -> [ProviderPool] {
        Provider.allCases.compactMap { provider in
            let members = accounts.filter { $0.provider == provider }
                .sorted { ($0.isDisabled ? 1 : 0, $0.name) < ($1.isDisabled ? 1 : 0, $1.name) }
            guard !members.isEmpty else { return nil }

            var order: [String] = []
            var groups: [String: [LimitWindow]] = [:]
            for account in members where !account.isDisabled {
                for window in account.windows {
                    if groups[window.id] == nil { order.append(window.id) }
                    groups[window.id, default: []].append(window)
                }
            }
            let windows = order.compactMap { id -> PooledWindow? in
                guard let group = groups[id], let first = group.first else { return nil }
                let remaining = group.map { $0.remainingFraction(at: now) }.reduce(0, +)
                return PooledWindow(
                    id: id,
                    label: first.label,
                    remainingFraction: remaining / Double(group.count),
                    accountCount: group.count,
                    nextReset: group.compactMap { $0.upcomingReset(at: now) }.min()
                )
            }
            // 5-hour and weekly lead; other windows keep the order they were first seen in.
            let ordered = windows.enumerated()
                .sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }
                .map(\.element)
            return ProviderPool(provider: provider, accounts: members, windows: ordered)
        }
    }

    private static func rank(_ id: String) -> Int {
        switch id {
        case "5h": 0
        case "7d": 1
        default: 2
        }
    }
}
