import Foundation
import Observation
import ProxyLimits

/// Holds the hub settings and the latest limits, and keeps them fresh.
@MainActor
@Observable
final class LimitsStore {
    private(set) var hubURL: URL?
    /// False until the saved key has been looked up at launch.
    private(set) var isLoaded = false
    private(set) var accounts: [Account] = []
    private(set) var lastUpdated: Date?
    private(set) var error: HubError?
    private(set) var isRefreshing = false
    /// Advances with every poll so the menu bar icon follows the clock between readings.
    private(set) var now = Date()

    /// Reading limits costs the providers nothing (the hub answers from memory), so a minute
    /// is about how stale a glance at the menu bar can get.
    private static let pollInterval: Duration = .seconds(60)
    private static let hubURLKey = "hubURL"

    /// The key for `hubURL`, read from the keychain once and kept in memory.
    private var managementKey: String?
    private var pollTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hubURL = defaults.string(forKey: Self.hubURLKey).flatMap(HubClient.normalizedBaseURL)
        Task {
            if let hubURL {
                managementKey = await Keychain.key(for: hubURL)
            }
            isLoaded = true
            startPolling()
        }
    }

    var isConfigured: Bool { hubURL != nil && managementKey != nil }

    var pools: [ProviderPool] { Pool.pools(from: accounts, at: now) }

    /// The pool the menu bar gauges show: Claude if it has limits to show, otherwise Codex.
    var menuBarPool: ProviderPool? {
        let pools = pools
        return pools.first { !$0.windows.isEmpty } ?? pools.first
    }

    /// Whether the limits on hand can no longer be trusted at a glance: the hub rejected the
    /// key, or it has not answered for several polls.
    var isOutOfDate: Bool {
        guard let error else { return false }
        guard error != .keyRejected, let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) > 5 * 60
    }

    /// Whether a usable key is already saved for `hub`, so Settings can offer to keep it.
    /// A key the hub rejected is not usable: asking again with it counts toward the ban.
    func hasSavedKey(for hub: URL) -> Bool {
        hub == hubURL && managementKey != nil && error != .keyRejected
    }

    /// Saves the hub address with a newly typed key, or keeps the saved key when none was
    /// typed, then reads limits right away. Returns false when there is no key to use or it
    /// could not be stored.
    func save(hubURL newURL: URL, managementKey typedKey: String?) async -> Bool {
        let key: String
        if let typedKey {
            guard await Keychain.setKey(typedKey, for: newURL) else { return false }
            key = typedKey
        } else {
            guard hasSavedKey(for: newURL), let managementKey else { return false }
            key = managementKey
        }
        if newURL != hubURL {
            accounts = []
            lastUpdated = nil
        }
        hubURL = newURL
        managementKey = key
        defaults.set(newURL.absoluteString, forKey: Self.hubURLKey)
        error = nil
        startPolling()
        return true
    }

    /// Reads limits now and restarts the loop if an error had stopped it. Does nothing after a
    /// rejected key: every wrong attempt counts toward the hub's ban, so only saving new
    /// settings asks again.
    func refreshNow() {
        guard error != .keyRejected else { return }
        startPolling()
    }

    /// Called when the panel opens, so it never shows limits older than a few seconds and
    /// asks again right away if the hub has not answered yet.
    func refreshIfStale() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) <= 10 { return }
        guard lastUpdated != nil || error != nil else { return }
        refreshNow()
    }

    /// Polls until the hub rejects the key. Every other failure is asked again a minute
    /// later, so the widget recovers by itself when the hub comes back.
    private func startPolling() {
        pollTask?.cancel()
        guard let hubURL, let managementKey else { return }
        let client = HubClient(baseURL: hubURL, managementKey: managementKey)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(with: client)
                if self.error == .keyRejected { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func refresh(with client: HubClient) async {
        isRefreshing = true
        do {
            let fetched = try await client.fetchAccounts()
            // A cancelled poll belongs to settings that were just replaced.
            guard !Task.isCancelled else { return }
            accounts = fetched
            lastUpdated = Date()
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error
        }
        isRefreshing = false
        now = Date()
    }
}
