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
                        .padding(.bottom, pools.isEmpty ? Metrics.edge : 0)
                }
                if !pools.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(pools) { pool in
                                ProviderSection(pool: pool, now: now)
                            }
                        }
                        .padding(Metrics.edge)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: Metrics.scrollHeight)
                    .fixedSize(horizontal: false, vertical: true)
                } else if store.error == nil {
                    EmptyState(store: store)
                }
                Divider()
                Footer(store: store, now: now, openSettings: openSettings)
            }
        }
        .onAppear(perform: store.refreshIfStale)
    }
}

/// Spacing shared by every part of the panel. Section titles sit on `edge`; everything inside a
/// tile or an account row sits `inset` further in, on both sides.
enum Metrics {
    static let edge: CGFloat = 16
    static let inset: CGFloat = 12
    static let column: CGFloat = 58
    static let tileRadius: CGFloat = 12

    /// Tall enough that two providers fit without scrolling on most Macs, short enough that the
    /// footer (43pt) and the tallest error banner (about 120pt) still fit on the smallest screen.
    static var scrollHeight: CGFloat {
        let screen = NSScreen.screens.map(\.visibleFrame.height).min() ?? 800
        return max(480, screen - 190)
    }
}

extension Color {
    /// Text for names and readings. On the panel's material macOS blends the system label colors
    /// into the backdrop, which draws `.primary` mid-grey and, over a dark window, lighter than
    /// the captions under it. A color of our own is drawn as is.
    static let label = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.96, alpha: 1)
                : NSColor(white: 0.1, alpha: 1)
        }
    )
}

/// The color a limit earns. Healthy limits stay neutral so color only ever means "look at this".
enum Level {
    static func tint(_ remaining: Double) -> Color? {
        switch remaining {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: nil
        }
    }
}

/// Words for a pooled window's soonest reset. With several accounts it is only the first of
/// several resets, so it is "next", not the moment the whole pool refills.
private func resetText(_ window: PooledWindow, now: Date) -> String {
    guard let reset = window.nextReset else { return "No reset scheduled" }
    let lead = window.accountCount > 1 ? "Next reset in" : "Resets in"
    return "\(lead) \(LimitFormat.duration(until: reset, from: now))"
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
                    .foregroundStyle(Color.label)
                    .accessibilityAddTraits(.isHeader)
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
                VStack(spacing: 8) {
                    if !mainWindows.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(mainWindows) { window in
                                WindowTile(window: window, activeAccounts: pool.activeAccountCount, now: now)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(extraWindows) { window in
                        ExtraWindowTile(window: window, activeAccounts: pool.activeAccountCount, now: now)
                    }
                }
            }
            AccountList(accounts: pool.accounts, columns: columns, now: now)
        }
    }

    /// The 5-hour and weekly windows get a tile and a column each. Model-scoped windows are
    /// listed under the tiles and under the accounts that report them.
    private var mainWindows: [PooledWindow] {
        let main = pool.windows.filter { ["5h", "7d"].contains($0.id) }
        if !main.isEmpty { return main }
        // A provider with other window lengths: its first unscoped windows, never a model's.
        return Array(pool.windows.filter { !$0.id.contains("_") && !$0.id.contains(":") }.prefix(2))
    }

    private var extraWindows: [PooledWindow] {
        let main = Set(mainWindows.map(\.id))
        return pool.windows.filter { !main.contains($0.id) }
    }

    /// The tiles' windows. With nothing pooled (every account disabled), the 5-hour and weekly
    /// windows the accounts still report, so their readings keep their columns.
    private var columns: [Column] {
        if !mainWindows.isEmpty { return mainWindows.map { Column(id: $0.id, title: $0.label) } }
        let windows = pool.accounts.flatMap(\.windows)
        return ["5h", "7d"].compactMap { id in
            windows.first { $0.id == id }.map { Column(id: id, title: $0.label) }
        }
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Reading(remaining: window.remainingFraction, size: 30)
                .padding(.top, 2)
            Meter(remaining: window.remainingFraction, height: 5)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(resetText(window, now: now))
                if window.accountCount < activeAccounts {
                    Text("\(window.accountCount) of \(activeAccounts) reporting")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pooled \(window.label)")
        .accessibilityValue(detail.joined(separator: ". "))
    }

    private var detail: [String] {
        var parts = ["\(LimitFormat.percent(window.remainingFraction)) left", resetText(window, now: now)]
        if window.accountCount < activeAccounts {
            parts.append("\(window.accountCount) of \(activeAccounts) reporting")
        }
        return parts
    }
}

/// "33% left", with the number set large. Only the number takes the warning color.
private struct Reading: View {
    let remaining: Double
    let size: CGFloat

    var body: some View {
        let number = String(LimitFormat.percent(remaining).dropLast())
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(
                "\(Text(number).font(.system(size: size, weight: .semibold)))\(Text("%").font(.system(size: size * 0.57, weight: .semibold)))"
            )
            .foregroundStyle(Level.tint(remaining) ?? .label)
            Text("left")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }
}

/// A model-scoped pooled window: the same reading as a tile, in one slim row.
private struct ExtraWindowTile: View {
    let window: PooledWindow
    let activeAccounts: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Reading(remaining: window.remainingFraction, size: 20)
            }
            Meter(remaining: window.remainingFraction, height: 5)
                .padding(.top, 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 8)
        }
        .monospacedDigit()
        .tile()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pooled \(window.label)")
        .accessibilityValue("\(LimitFormat.percent(window.remainingFraction)) left. \(detail)")
    }

    private var detail: String {
        var parts = [resetText(window, now: now)]
        if window.accountCount < activeAccounts {
            parts.append("\(window.accountCount) of \(activeAccounts) reporting")
        }
        return parts.joined(separator: " · ")
    }
}

private extension View {
    /// The raised surface every pooled reading sits on.
    func tile() -> some View {
        padding(Metrics.inset)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Metrics.tileRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.tileRadius)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

// MARK: Accounts

/// A column of the account table: one of the windows that has a tile above.
private struct Column: Identifiable {
    let id: String
    let title: String
}

private struct AccountList: View {
    let accounts: [Account]
    let columns: [Column]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Accounts")
                Spacer()
                ForEach(columns) { column in
                    Text(column.title)
                        .lineLimit(1)
                        .frame(width: Metrics.column, alignment: .trailing)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, 6)
            .accessibilityHidden(true)

            Divider().padding(.horizontal, Metrics.inset)

            ForEach(accounts) { account in
                AccountRow(account: account, columns: columns, now: now)
            }
        }
        .padding(.top, 8)
    }
}

private struct AccountRow: View {
    let account: Account
    let columns: [Column]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        if let tint = status.tint {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(tint)
                                .accessibilityHidden(true)
                        }
                        // A long plan gives way before the state does: a countdown never gets cut.
                        HStack(spacing: 0) {
                            if let plan = account.plan {
                                Text("\(plan.capitalized) · ").lineLimit(1)
                            }
                            Text(status.text).lineLimit(1).layoutPriority(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
                .layoutPriority(1)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                ForEach(columns) { column in
                    WindowCell(
                        title: column.title,
                        window: account.windows.first { $0.id == column.id },
                        isDisabled: account.isDisabled,
                        now: now
                    )
                    .frame(width: Metrics.column, alignment: .trailing)
                }
            }
            ForEach(extraWindows) { window in
                ScopedWindowLine(window: window, isDisabled: account.isDisabled, now: now)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 8)
        .opacity(account.isDisabled ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    private var extraWindows: [LimitWindow] {
        account.windows.filter { window in !columns.contains { $0.id == window.id } }
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
        guard let observedAt = account.observedAt else { return ("No data yet", nil) }
        return ("Read \(LimitFormat.age(of: observedAt, at: now))", nil)
    }
}

/// One account's reading for one column: the share left and when it resets.
private struct WindowCell: View {
    let title: String
    let window: LimitWindow?
    let isDisabled: Bool
    let now: Date

    var body: some View {
        if let window {
            let remaining = window.remainingFraction(at: now)
            let reset = window.upcomingReset(at: now).map { LimitFormat.duration(until: $0, from: now) }
            VStack(alignment: .trailing, spacing: 2) {
                Text(LimitFormat.percent(remaining))
                    .font(.system(size: 13, weight: .semibold))
                    // A benched account is not in the pool, so its low reading is no warning.
                    .foregroundStyle((isDisabled ? nil : Level.tint(remaining)) ?? .label)
                Text(reset ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(
                "\(LimitFormat.percent(remaining)) left" + (reset.map { ", resets in \($0)" } ?? "")
            )
        } else {
            Text("—")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .accessibilityLabel(title)
                .accessibilityValue("No reading")
        }
    }
}

/// A model-scoped window of one account, on its own line under the account.
private struct ScopedWindowLine: View {
    let window: LimitWindow
    let isDisabled: Bool
    let now: Date

    var body: some View {
        let remaining = window.remainingFraction(at: now)
        let reset = window.upcomingReset(at: now).map { LimitFormat.duration(until: $0, from: now) }
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(window.label + (reset.map { " · \($0)" } ?? ""))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(LimitFormat.percent(remaining))
                .fontWeight(.semibold)
                .foregroundStyle((isDisabled ? nil : Level.tint(remaining)) ?? .label)
                .frame(width: Metrics.column, alignment: .trailing)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue("\(LimitFormat.percent(remaining)) left" + (reset.map { ", resets in \($0)" } ?? ""))
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
                    .foregroundStyle(Color.label)
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
        .padding(Metrics.inset)
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
            // The address may be cut in the middle, but the port and the age always show.
            HStack(spacing: 0) {
                if let hub = store.hubURL, let host = hub.host() {
                    Text(hub.port.map { "\(host):\($0)" } ?? host)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let updated = store.lastUpdated {
                    Text(" · updated \(LimitFormat.age(of: updated, at: now))")
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Spacer(minLength: 8)
            FooterButton(symbol: "arrow.clockwise", help: "Read limits now", action: store.refreshNow)
                .disabled(store.isRefreshing || store.error == .keyRejected)
            FooterButton(symbol: "gearshape", help: "Settings", action: openSettings)
        }
        .padding(.leading, Metrics.edge)
        .padding(.trailing, Metrics.edge - 6)
        .padding(.vertical, 8)
    }
}

/// A borderless icon button that shows its hit area on hover, like the ones in Control Center.
private struct FooterButton: View {
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
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
