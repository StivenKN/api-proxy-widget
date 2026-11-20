import ProxyLimits
import SwiftUI

/// The panel under the menu bar item: pooled limits per provider, then each account.
struct LimitsView: View {
    let store: LimitsStore
    let openSettings: () -> Void

    var body: some View {
        // Countdowns and "read 5m ago" follow the clock while the panel is open.
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let now = max(timeline.date, store.now)
            let pools = Pool.pools(from: store.accounts, at: now)
            VStack(alignment: .leading, spacing: 0) {
                if let error = store.error {
                    ErrorBanner(error: error, hasData: !store.accounts.isEmpty, retry: store.refreshNow)
                }
                if !pools.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(pools) { pool in
                                ProviderSection(pool: pool, now: now)
                            }
                        }
                        .padding(14)
                    }
                    .frame(maxHeight: 640)
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

private struct ProviderSection: View {
    let pool: ProviderPool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(pool.provider.displayName).font(.headline)
                Spacer()
                Text(accountSummary).font(.caption).foregroundStyle(.secondary)
            }
            if pool.windows.isEmpty {
                Text("No limits read yet. The hub learns them from each account's traffic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pool.windows) { window in
                    PooledWindowRow(window: window, activeAccounts: pool.activeAccountCount, now: now)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(pool.accounts) { account in
                    AccountRow(account: account, now: now)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var accountSummary: String {
        let total = pool.accounts.count
        let active = pool.activeAccountCount
        let noun = total == 1 ? "account" : "accounts"
        return active == total ? "\(total) \(noun)" : "\(active) of \(total) \(noun) active"
    }
}

private struct PooledWindowRow: View {
    let window: PooledWindow
    let activeAccounts: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.subheadline)
                Spacer()
                Text("\(LimitFormat.percent(window.remainingFraction)) left")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Gauge(remaining: window.remainingFraction, height: 6)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let reset = window.nextReset {
            parts.append("Next reset in \(LimitFormat.duration(until: reset, from: now))")
        }
        if window.accountCount < activeAccounts {
            parts.append("\(window.accountCount) of \(activeAccounts) accounts reporting")
        }
        return parts.isEmpty ? "No reset scheduled" : parts.joined(separator: " · ")
    }
}

private struct AccountRow: View {
    let account: Account
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = account.plan {
                    Text(plan.capitalized).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let status {
                    Text(status.text).font(.caption2).foregroundStyle(status.color)
                }
            }
            if !account.windows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(account.windows) { window in
                        GridRow {
                            Text(window.label)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Gauge(remaining: window.remainingFraction(at: now), height: 4)
                            Text(LimitFormat.percent(window.remainingFraction(at: now)))
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(window.upcomingReset(at: now).map { LimitFormat.duration(until: $0, from: now) } ?? "—")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.caption2)
            }
        }
        .opacity(account.isDisabled ? 0.5 : 1)
    }

    private var status: (text: String, color: Color)? {
        if account.isDisabled { return ("Disabled", .secondary) }
        if account.isUnavailable {
            if let back = account.availableAgainAt, back > now {
                return ("Cooling down · \(LimitFormat.duration(until: back, from: now))", .orange)
            }
            return ("Unavailable", .orange)
        }
        guard let observedAt = account.observedAt else { return ("No data yet", .secondary) }
        return ("Read \(LimitFormat.age(of: observedAt, at: now))", .secondary)
    }
}

/// A bar that is full when the whole limit is left and drains as it is used.
private struct Gauge: View {
    let remaining: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if remaining > 0 {
                    Capsule().fill(color).frame(width: max(height, proxy.size.width * min(1, remaining)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch remaining {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: .green
        }
    }
}

private struct ErrorBanner: View {
    let error: HubError
    let hasData: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                if hasData {
                    Text("Showing the last limits that were read.").font(.caption2).foregroundStyle(.secondary)
                }
                if error == .keyRejected {
                    Text("Save the right key in Settings. The widget stopped asking so the hub doesn't ban this Mac.")
                        .font(.caption2)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

private struct EmptyState: View {
    let store: LimitsStore

    var body: some View {
        VStack(spacing: 6) {
            if store.lastUpdated == nil {
                ProgressView().controlSize(.small)
                Text("Reading limits…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No Claude or Codex accounts on this hub.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(14)
    }
}

private struct Footer: View {
    let store: LimitsStore
    let now: Date
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                if let hub = store.hubURL, let host = hub.host() {
                    Text(hub.port.map { "\(host):\($0)" } ?? host).lineLimit(1).truncationMode(.middle)
                }
                if let updated = store.lastUpdated {
                    Text("Updated \(LimitFormat.age(of: updated, at: now))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Spacer()
            Button(action: store.refreshNow) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Read limits now")
            .disabled(store.isRefreshing || store.error == .keyRejected)
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
