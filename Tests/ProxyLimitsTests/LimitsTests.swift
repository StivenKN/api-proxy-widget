import Foundation
import Testing

@testable import ProxyLimits

private func date(_ epoch: TimeInterval) -> Date { Date(timeIntervalSince1970: epoch) }

private func isClose(_ a: Double?, _ b: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-9
}

@Suite struct SignalParserTests {
    @Test func readsClaudeWindowsFromUnifiedHeaders() throws {
        let ada = try #require(fixtureAccounts().first { $0.id.contains("aaaa1111") })

        #expect(ada.name == "ada@example.com")
        #expect(ada.windows.map(\.id) == ["5h", "7d"])
        #expect(ada.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(ada.windows.map(\.usedFraction) == [0.2, 0.27])
        #expect(ada.windows.map(\.resetsAt) == [date(1_795_150_800), date(1_795_356_000)])
        #expect(isClose(ada.observedAt?.timeIntervalSince1970, 1_795_136_709.482))
    }

    @Test func aClaudeReadingWithoutA5HourWindowMeansThatWindowIsUnused() throws {
        // Anthropic sends no 5-hour headers while the 5-hour window has no usage.
        let grace = try #require(fixtureAccounts().first { $0.id.contains("bbbb2222") })

        #expect(grace.windows.map(\.id) == ["5h", "7d"])
        #expect(grace.windows.first?.usedFraction == 0)
        #expect(grace.windows.first?.resetsAt == nil)
    }

    @Test func aClaudeAccountWithNoReadingHasNoWindows() {
        #expect(SignalParser.windows(provider: .claude, signals: [:], observedAt: nil).isEmpty)
    }

    @Test func aRejectedWindowIsFullyUsedEvenWithoutAUtilization() throws {
        let linus = try #require(fixtureAccounts().first { $0.id.contains("cccc3333") })

        #expect(linus.windows.map(\.id) == ["5h", "7d", "7d_sonnet"])
        #expect(linus.windows.map(\.usedFraction) == [1, 0.9, 1])
        #expect(linus.windows.last?.label == "Weekly · Sonnet")
        #expect(linus.isUnavailable)
        #expect(linus.availableAgainAt == date(1_795_147_200))
    }

    @Test func anAPIKeyCredentialNeverExposesItsKey() throws {
        let apiKey = try #require(fixtureAccounts().first { $0.id == "claude-apikey-1" })

        #expect(apiKey.name == "claude-apikey-1")
        #expect(apiKey.windows.isEmpty)
        #expect(apiKey.observedAt == nil)
        #expect(!String(describing: apiKey).contains("sk-ant"))
    }

    @Test func namesCodexWindowsByTheirLength() throws {
        let codex = try #require(fixtureAccounts().first { $0.provider == .codex })

        #expect(codex.plan == "pro")
        #expect(codex.windows.map(\.id) == ["5h", "7d", "gpt-5.3-codex-spark:7d"])
        #expect(codex.windows.map(\.label) == ["5-hour", "Weekly", "GPT-5.3-Codex-Spark · Weekly"])
        #expect(codex.windows.map(\.usedFraction) == [0.51, 0.17, 0.35])
        // No absolute reset on the 5-hour window: observed 23:00:00Z plus 7200 seconds.
        #expect(codex.windows.map(\.resetsAt) == [date(1_795_136_400), date(1_795_650_000), date(1_795_700_000)])
    }

    @Test func codexSlotsFollowTheWindowLengthNotTheSlotName() {
        // Some plans report the weekly window in the primary slot.
        let windows = SignalParser.windows(
            provider: .codex,
            signals: [
                "x-codex-primary-used-percent": "40",
                "x-codex-primary-window-minutes": "10080",
                "x-codex-secondary-used-percent": "12",
            ],
            observedAt: nil
        )
        #expect(windows.map(\.id) == ["7d", "secondary"])
        #expect(windows.map(\.label) == ["Weekly", "Secondary"])
    }

    @Test func anExtraCodexLimitHasOneIdHoweverTheHubSawIt() {
        // The hub prefixes an extra limit with a short name for HTTP traffic and with
        // "additional-<name>" for websocket traffic.
        func ids(_ prefix: String) -> [String] {
            SignalParser.windows(
                provider: .codex,
                signals: [
                    "\(prefix)-limit-name": "GPT-5.3-Codex-Spark",
                    "\(prefix)-primary-used-percent": "20",
                    "\(prefix)-primary-window-minutes": "300",
                ],
                observedAt: nil
            ).map(\.id)
        }
        #expect(ids("X-Codex-Bengalfox") == ["gpt-5.3-codex-spark:5h"])
        #expect(ids("X-Codex-Additional-Gpt-5.3-Codex-Spark") == ["gpt-5.3-codex-spark:5h"])
    }

    @Test func ignoresValuesThatAreNotNumbers() {
        let windows = SignalParser.windows(
            provider: .claude,
            signals: [
                "anthropic-ratelimit-unified-5h-utilization": "soon",
                "anthropic-ratelimit-unified-7d-utilization": "nan",
                "anthropic-ratelimit-unified-7d-reset": "tomorrow",
            ],
            observedAt: nil
        )
        #expect(windows.isEmpty)
    }
}

@Suite struct LimitWindowTests {
    private let window = LimitWindow(id: "5h", label: "5-hour", usedFraction: 0.8, resetsAt: date(1000))

    @Test func keepsItsReadingUntilTheResetTime() {
        #expect(isClose(window.remainingFraction(at: date(999)), 0.2))
        #expect(window.upcomingReset(at: date(999)) == date(1000))
    }

    @Test func isFullAgainOnceTheResetTimeHasPassed() {
        #expect(window.remainingFraction(at: date(1000)) == 1)
        #expect(window.upcomingReset(at: date(1000)) == nil)
    }

    @Test func clampsUtilizationAboveTheLimit() {
        #expect(LimitWindow(id: "7d", label: "Weekly", usedFraction: 1.02, resetsAt: nil).usedFraction == 1)
        #expect(LimitWindow(id: "7d", label: "Weekly", usedFraction: -0.1, resetsAt: nil).usedFraction == 0)
    }
}

@Suite struct PoolTests {
    @Test func averagesEachWindowOverTheAccountsThatReportIt() throws {
        let pools = try Pool.pools(from: fixtureAccounts(), at: fixtureNow)
        let claude = try #require(pools.first { $0.provider == .claude })

        #expect(pools.map(\.provider) == [.claude, .codex])
        #expect(claude.windows.map(\.id) == ["5h", "7d", "7d_sonnet"])

        // ada has 80% left, grace's window is unused and linus is rejected. The API-key
        // entry has no reading and is left out.
        let fiveHour = try #require(claude.window("5h"))
        #expect(isClose(fiveHour.remainingFraction, (0.8 + 1 + 0) / 3))
        #expect(fiveHour.accountCount == 3)
        #expect(fiveHour.nextReset == date(1_795_147_200))

        // ada 73%, grace 39%, linus 10%. The benched account's 1% is left out.
        let weekly = try #require(claude.window("7d"))
        #expect(isClose(weekly.remainingFraction, (0.73 + 0.39 + 0.1) / 3))
        #expect(weekly.accountCount == 3)
        #expect(weekly.nextReset == date(1_795_356_000))
    }

    @Test func listsBenchedAccountsLastAndDoesNotCountThemAsActive() throws {
        let claude = try #require(Pool.pools(from: fixtureAccounts(), at: fixtureNow).first)

        #expect(claude.accounts.map(\.name) == [
            "ada@example.com", "claude-apikey-1", "grace@example.com", "linus@example.com", "benched@example.com",
        ])
        #expect(claude.activeAccountCount == 4)
    }

    @Test func aWindowPastItsResetCountsAsFull() throws {
        let codex = try #require(Pool.pools(from: fixtureAccounts(), at: fixtureNow).last)

        // The 5-hour window reset at 01:00Z, before `fixtureNow`, so its 51% reading is stale.
        let fiveHour = try #require(codex.window("5h"))
        #expect(fiveHour.remainingFraction == 1)
        #expect(fiveHour.nextReset == nil)
        #expect(isClose(codex.window("7d")?.remainingFraction, 0.83))
    }

    @Test func aPoolOfOnlyBenchedAccountsHasNoWindows() {
        let benched = Account(
            id: "x", provider: .claude, name: "x", isDisabled: true,
            windows: [LimitWindow(id: "7d", label: "Weekly", usedFraction: 0.5, resetsAt: nil)]
        )
        let pool = Pool.pools(from: [benched], at: fixtureNow).first
        #expect(pool?.windows.isEmpty == true)
        #expect(pool?.activeAccountCount == 0)
    }
}

@Suite struct LimitFormatTests {
    @Test(arguments: [(1.0, "100%"), (0.409, "40%"), (1 - 0.34, "66%"), (0.004, "1%"), (0.0, "0%"), (1.7, "100%"), (-1.0, "0%")] as [(Double, String)])
    func percent(fraction: Double, expected: String) {
        #expect(LimitFormat.percent(fraction) == expected)
    }

    @Test(arguments: [
        (30.0, "under 1m"), (60.0, "1m"), (3540.0, "59m"), (3600.0, "1h"), (8040.0, "2h 14m"),
        (86400.0, "1d"), (277_140.0, "3d 4h"),
    ] as [(Double, String)])
    func duration(seconds: Double, expected: String) {
        #expect(LimitFormat.duration(until: date(seconds), from: date(0)) == expected)
    }

    @Test(arguments: [(12.0, "just now"), (300.0, "5m ago"), (10800.0, "3h ago"), (172_800.0, "2d ago"), (-5.0, "just now")] as [(Double, String)])
    func age(seconds: Double, expected: String) {
        #expect(LimitFormat.age(of: date(0), at: date(seconds)) == expected)
    }
}
