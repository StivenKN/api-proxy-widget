import ProxyLimits
import SwiftUI

/// The panel under the menu bar item: pooled limits per provider, then each account.
struct LimitsView: View {
    let store: LimitsStore
    let openSettings: () -> Void

    var body: some View {
        // Countdowns and "5m ago" follow the clock while the panel is open.
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let now = max(timeline.date, store.now)
            let pools = Pool.pools(from: store.accounts, at: now)
            VStack(alignment: .leading, spacing: 0) {
                if let error = store.error {
                    ErrorBanner(error: error, hasData: !store.accounts.isEmpty, retry: store.refreshNow)
                        .padding([.horizontal, .top], Metrics.edge)
                }
                if !pools.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(pools) { pool in
                                ProviderSection(pool: pool, now: now)
                            }
                        }
                        .padding(Metrics.edge)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 640)
                    .fixedSize(horizontal: false, vertical: true)
                } else if store.error == nil {
                    EmptyState(store: store)
                }
                Divider().opacity(0.6)
                Footer(store: store, now: now, openSettings: openSettings)
            }
        }
        .onAppear(perform: store.refreshIfStale)
    }
}

/// Spacing shared by every part of the panel, so all content sits on the same left and right edge.
enum Metrics {
    static let edge: CGFloat = 16
    static let column: CGFloat = 68
    static let tileRadius: CGFloat = 12
}

/// How full a limit is, and the color it earns. Healthy limits stay neutral so color only ever
/// means "look at this".
enum Level {
    static func tint(_ remaining: Double) -> Color? {
        switch remaining {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: nil
        }
    }
}

// MARK: Provider

private struct ProviderSection: View {
    let pool: ProviderPool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(pool.provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(accountSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if pool.windows.isEmpty {
                Text(
                    pool.activeAccountCount == 0
                        ? "Every account here is disabled on the hub."
                        : "No limits read yet. The hub learns them from each account's traffic."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(mainWindows) { window in
                        WindowTile(window: window, activeAccounts: pool.activeAccountCount, now: now)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                ForEach(extraWindows) { window in
                    ExtraWindowTile(window: window, activeAccounts: pool.activeAccountCount, now: now)
                }
            }
            AccountList(accounts: pool.accounts, columns: mainWindows.map(\.id), now: now)
        }
    }

    /// The 5-hour and weekly windows get a tile and a column each. Model-scoped windows are
    /// listed under the tiles and under the accounts that report them.
    private var mainWindows: [PooledWindow] {
        let main = pool.windows.filter { ["5h", "7d"].contains($0.id) }
        return main.isEmpty ? Array(pool.windows.prefix(2)) : main
    }

    private var extraWindows: [PooledWindow] {
        let main = Set(mainWindows.map(\.id))
        return pool.windows.filter { !main.contains($0.id) }
    }

    private var accountSummary: String {
        let total = pool.accounts.count
        let active = pool.activeAccountCount
        let noun = total == 1 ? "account" : "accounts"
        return active == total ? "\(total) \(noun)" : "\(active) of \(total) \(noun) active"
    }
}

/// A pooled window as a tile: what is left, set large, and when it next resets.
private struct WindowTile: View {
    let window: PooledWindow
    let activeAccounts: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(window.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(number)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .foregroundStyle(Level.tint(window.remainingFraction) ?? .primary)
            .padding(.top, 2)
            Meter(remaining: window.remainingFraction, height: 5)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(reset)
                if window.accountCount < activeAccounts {
                    Text("\(window.accountCount) of \(activeAccounts) reporting")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
        .accessibilityElement(children: .combine)
    }

    private var number: String {
        String(LimitFormat.percent(window.remainingFraction).dropLast())
    }

    private var reset: String {
        window.nextReset.map { "Resets in \(LimitFormat.duration(until: $0, from: now))" } ?? "No reset scheduled"
    }
}

/// A model-scoped pooled window: the same reading as a tile, in one slim row.
private struct ExtraWindowTile: View {
    let window: PooledWindow
    let activeAccounts: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(LimitFormat.percent(window.remainingFraction).dropLast()))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("%").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Level.tint(window.remainingFraction) ?? .primary)
            }
            Meter(remaining: window.remainingFraction, height: 4)
        }
        .monospacedDigit()
        .tile()
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let reset = window.nextReset {
            parts.append("Resets in \(LimitFormat.duration(until: reset, from: now))")
        }
        if window.accountCount < activeAccounts {
            parts.append("\(window.accountCount) of \(activeAccounts) reporting")
        }
        return parts.isEmpty ? "No reset scheduled" : parts.joined(separator: " · ")
    }
}

private extension View {
    /// The quiet raised surface every pooled reading sits on.
    func tile() -> some View {
        padding(12)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Metrics.tileRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.tileRadius)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

// MARK: Accounts

private struct AccountList: View {
    let accounts: [Account]
    let columns: [String]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("Accounts")
                Spacer()
                ForEach(columns, id: \.self) { id in
                    Text(columnTitle(id)).frame(width: Metrics.column, alignment: .trailing)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, AccountRow.inset)
            .padding(.bottom, 2)

            ForEach(accounts) { account in
                AccountRow(account: account, columns: columns, now: now)
            }
        }
        .padding(.top, 6)
    }

    private func columnTitle(_ id: String) -> String {
        accounts.lazy.flatMap(\.windows).first { $0.id == id }.map { window in
            switch window.id {
            case "5h": "5-hour"
            case "7d": "Weekly"
            default: window.label
            }
        } ?? id
    }
}

private struct AccountRow: View {
    static let inset: CGFloat = 8

    let account: Account
    let columns: [String]
    let now: Date

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status.text)
                        .font(.system(size: 11))
                        .foregroundStyle(status.tint ?? .secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                ForEach(columns, id: \.self) { id in
                    WindowCell(window: account.windows.first { $0.id == id }, now: now)
                        .frame(width: Metrics.column, alignment: .trailing)
                }
            }
            ForEach(extraWindows) { window in
                HStack(spacing: 6) {
                    Text(window.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    WindowCell(window: window, now: now)
                        .frame(width: Metrics.column, alignment: .trailing)
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(isHovered ? 0.05 : 0))
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .opacity(account.isDisabled ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }

    private var extraWindows: [LimitWindow] {
        account.windows.filter { !columns.contains($0.id) }
    }

    /// What the hub says about the account: benched, cooling down, or how old its reading is.
    private var status: (text: String, tint: Color?) {
        if account.isDisabled { return ("Disabled", nil) }
        if account.isUnavailable {
            if let back = account.availableAgainAt, back > now {
                return ("Cooling down · \(LimitFormat.duration(until: back, from: now))", .orange)
            }
            return ("Unavailable", .orange)
        }
        let plan = account.plan.map { "\($0.capitalized) · " } ?? ""
        guard let observedAt = account.observedAt else { return (plan + "No data yet", nil) }
        return (plan + "Read \(LimitFormat.age(of: observedAt, at: now))", nil)
    }
}

/// One account's reading for one window: a short bar, the share left and when it resets.
private struct WindowCell: View {
    let window: LimitWindow?
    let now: Date

    var body: some View {
        if let window {
            let remaining = window.remainingFraction(at: now)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Meter(remaining: remaining, height: 4).frame(width: 20)
                    Text(LimitFormat.percent(remaining))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Level.tint(remaining) ?? .primary)
                }
                Text(window.upcomingReset(at: now).map { LimitFormat.duration(until: $0, from: now) } ?? "—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        } else {
            Text("—")
                .font(.system(size: 12))
                .foregroundStyle(.quaternary)
                .accessibilityLabel("No reading")
        }
    }
}

// MARK: Gauges

/// A bar that is full when the whole limit is left and drains as it is used.
private struct Meter: View {
    let remaining: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                if remaining > 0 {
                    // Never narrower than a dot, so "a little left" doesn't look empty.
                    Capsule()
                        .fill(Level.tint(remaining) ?? .primary.opacity(0.78))
                        .frame(width: max(height, proxy.size.width * min(1, remaining)))
                }
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.4), value: remaining)
        .accessibilityHidden(true)
    }
}

// MARK: States

private struct ErrorBanner: View {
    let error: HubError
    let hasData: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(error.message)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if hasData {
                    Text("Showing the last limits that were read.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if error == .keyRejected {
                    Text("Save the right key in Settings. The widget stopped asking so the hub doesn't ban this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            // A rejected key is not retried: every wrong attempt counts toward the hub's ban.
            if error != .keyRejected {
                Button("Retry", action: retry).controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Metrics.tileRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.tileRadius)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct EmptyState: View {
    let store: LimitsStore

    var body: some View {
        VStack(spacing: 8) {
            if store.lastUpdated == nil {
                ProgressView().controlSize(.small)
                Text("Reading limits…")
            } else {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                Text("No Claude or Codex accounts on this hub.")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 96)
        .padding(Metrics.edge)
    }
}

private struct Footer: View {
    let store: LimitsStore
    let now: Date
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.error == nil ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            FooterButton(symbol: "arrow.clockwise", help: "Read limits now", action: store.refreshNow)
                .disabled(store.isRefreshing || store.error == .keyRejected)
            FooterButton(symbol: "gearshape", help: "Settings", action: openSettings)
        }
        .padding(.leading, Metrics.edge)
        .padding(.trailing, Metrics.edge - 6)
        .padding(.vertical, 8)
    }

    private var status: String {
        var parts: [String] = []
        if let hub = store.hubURL, let host = hub.host() {
            parts.append(hub.port.map { "\(host):\($0)" } ?? host)
        }
        if let updated = store.lastUpdated {
            parts.append("updated \(LimitFormat.age(of: updated, at: now))")
        }
        return parts.joined(separator: " · ")
    }
}

/// A borderless icon button that shows its hit area on hover, like the ones in Control Center.
struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(isHovered && isEnabled ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
