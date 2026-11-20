import Foundation

/// Turns the rate-limit headers the hub keeps per account into limit windows.
///
/// CLIProxyAPI stores the limit headers of each account's latest upstream response and returns
/// them as `quota.signals` on `/v0/management/auth-files`. Reading them costs the provider
/// nothing: no request leaves the hub.
enum SignalParser {
    static func windows(provider: Provider, signals: [String: String], observedAt: Date?) -> [LimitWindow] {
        let lowercased = Dictionary(
            signals.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) },
            uniquingKeysWith: { first, _ in first }
        )
        let windows =
            switch provider {
            case .claude: claudeWindows(lowercased)
            case .codex: codexWindows(lowercased, observedAt: observedAt)
            }
        return windows.sorted { ($0.rank, $0.window.id) < ($1.rank, $1.window.id) }.map(\.window)
    }

    private typealias Ranked = (rank: Int, window: LimitWindow)

    // MARK: Claude

    /// `anthropic-ratelimit-unified-<window>-<field>`, where the window is `5h`, `7d` or a
    /// model-scoped one such as `7d_sonnet`. Utilization is a 0...1 fraction and reset is epoch
    /// seconds.
    private static func claudeWindows(_ signals: [String: String]) -> [Ranked] {
        let prefix = "anthropic-ratelimit-unified-"
        var fields: [String: [String: String]] = [:]
        for (key, value) in signals where key.hasPrefix(prefix) {
            let parts = key.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, ["utilization", "status", "reset"].contains(parts[1]) else { continue }
            // Overage is paid extra usage, not a limit window.
            guard parts[0] != "overage" else { continue }
            fields[String(parts[0]), default: [:]][String(parts[1])] = value
        }
        var windows: [Ranked] = fields.compactMap { id, field in
            let rejected = field["status"] == "rejected"
            guard let used = rejected ? 1 : field["utilization"].flatMap(Double.init), used.isFinite else {
                return nil
            }
            let window = LimitWindow(
                id: id,
                label: claudeLabel(id),
                usedFraction: used,
                resetsAt: field["reset"].flatMap(epochDate)
            )
            return (windowRank(id), window)
        }
        // Anthropic leaves the 5-hour headers out while that window has no usage, so a
        // reading with a weekly window and no 5-hour one means the 5-hour window is unused.
        // CLIProxyAPI reads it the same way when it routes (QuotaWindowIdle).
        if windows.contains(where: { $0.window.id == "7d" }), !windows.contains(where: { $0.window.id == "5h" }) {
            windows.append((windowRank("5h"), LimitWindow(id: "5h", label: claudeLabel("5h"), usedFraction: 0, resetsAt: nil)))
        }
        return windows
    }

    private static func claudeLabel(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard let base = parts.first else { return id }
        let baseLabel =
            switch base {
            case "5h": "5-hour"
            case "7d": "Weekly"
            default: String(base)
            }
        guard parts.count == 2 else { return baseLabel }
        return "\(baseLabel) · \(parts[1].replacingOccurrences(of: "_", with: " ").capitalized)"
    }

    // MARK: Codex

    /// `x-codex-[<limit>-]<primary|secondary>-<field>`. Used percent is 0...100. Which slot is
    /// the 5-hour window and which the weekly one depends on the plan, so the window length
    /// decides. Extra limits (a separate model allowance, for example) carry a limit name.
    /// The hub spells an extra limit's header prefix differently for HTTP and websocket
    /// traffic, so the limit name, when there is one, identifies it across accounts.
    private static func codexWindows(_ signals: [String: String], observedAt: Date?) -> [Ranked] {
        let prefix = "x-codex-"
        let suffixes = ["used-percent", "window-minutes", "reset-at", "reset-after-seconds"]
        var slots: [String: [String: String]] = [:]
        for (key, value) in signals where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            guard let suffix = suffixes.first(where: { rest.hasSuffix("-" + $0) }) else { continue }
            let slotKey = String(rest.dropLast(suffix.count + 1))
            guard slotKey.hasSuffix("primary") || slotKey.hasSuffix("secondary") else { continue }
            slots[slotKey, default: [:]][suffix] = value
        }
        return slots.compactMap { slotKey, field in
            guard let percent = field["used-percent"].flatMap(Double.init), percent.isFinite else {
                return nil
            }
            let slot = slotKey.hasSuffix("primary") ? "primary" : "secondary"
            let limit = String(slotKey.dropLast(slot.count)).trimmingCharacters(in: ["-"])
            let minutes = field["window-minutes"].flatMap(Int.init)
            let (id, label) = codexWindowName(minutes: minutes, slot: slot)
            let resetsAt =
                field["reset-at"].flatMap(epochDate)
                ?? field["reset-after-seconds"].flatMap(Double.init).flatMap { seconds in
                    observedAt?.addingTimeInterval(seconds)
                }
            if limit.isEmpty {
                let window = LimitWindow(id: id, label: label, usedFraction: percent / 100, resetsAt: resetsAt)
                return (windowRank(id), window)
            }
            let limitName = signals["x-codex-\(limit)-limit-name"] ?? limit
            let window = LimitWindow(
                id: "\(limitName.lowercased()):\(id)",
                label: "\(limitName) · \(label)",
                usedFraction: percent / 100,
                resetsAt: resetsAt
            )
            return (3, window)
        }
    }

    private static func codexWindowName(minutes: Int?, slot: String) -> (id: String, label: String) {
        switch minutes {
        case 300: ("5h", "5-hour")
        case 10080: ("7d", "Weekly")
        case let minutes? where minutes > 0 && minutes % 1440 == 0: ("\(minutes / 1440)d", "\(minutes / 1440)-day")
        case let minutes? where minutes > 0 && minutes % 60 == 0: ("\(minutes / 60)h", "\(minutes / 60)-hour")
        case let minutes? where minutes > 0: ("\(minutes)m", "\(minutes)-minute")
        default: (slot, slot.capitalized)
        }
    }

    // MARK: Shared

    /// 5-hour first, weekly second, everything else after.
    private static func windowRank(_ id: String) -> Int {
        switch id {
        case "5h": 0
        case "7d": 1
        default: 2
        }
    }

    private static func epochDate(_ value: String) -> Date? {
        guard let seconds = Double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
