import Foundation
import QuotaCore
import XCTest
@testable import QuotaMenu

private actor FixtureReader: CredentialReading {
    var credentials: [QuotaProvider: LiveCredential] = [
        .codex: LiveCredential(provider: .codex, accessToken: "synthetic-A", accountHint: "A"),
        .fable: LiveCredential(provider: .fable, accessToken: "synthetic-C", accountHint: "C")
    ]
    var failures: [QuotaProvider: LiveReadError] = [:]
    func read(_ provider: QuotaProvider, allowInteraction: Bool) throws -> LiveCredential {
        if let error = failures[provider] { throw error }
        guard let value = credentials[provider] else { throw LiveReadError.notSignedIn }
        return value
    }
    func select(_ provider: QuotaProvider, account: String, token: String? = nil) {
        credentials[provider] = LiveCredential(provider: provider, accessToken: token ?? "synthetic-\(account)", accountHint: account)
        failures[provider] = nil
    }
    func fail(_ provider: QuotaProvider, error: LiveReadError) { failures[provider] = error }
    func use(_ credential: LiveCredential) {
        credentials[credential.provider] = credential
        failures[credential.provider] = nil
    }
}

private actor FixtureClient: QuotaFetching {
    var calls: [QuotaProvider: Int] = [:]
    var failures: [QuotaProvider: LiveReadError] = [:]
    var slowAccount: String?
    var active: [QuotaProvider: Int] = [:]
    var peaks: [QuotaProvider: Int] = [:]
    var cacheValue: UsageSnapshot?
    func cached(_ provider: QuotaProvider, credential: LiveCredential, at now: Date) -> UsageSnapshot? {
        guard provider == .fable, cacheValue?.accountID == credential.accountHint else { return nil }
        return cacheValue
    }
    func setCache(_ snapshot: UsageSnapshot) { cacheValue = snapshot }
    func fetch(_ provider: QuotaProvider, credential: LiveCredential) async throws -> UsageSnapshot {
        calls[provider, default: 0] += 1
        active[provider, default: 0] += 1
        peaks[provider] = max(peaks[provider, default: 0], active[provider, default: 0])
        defer { active[provider, default: 0] -= 1 }
        if credential.accountHint == slowAccount { try await Task.sleep(nanoseconds: 250_000_000) }
        if let error = failures[provider] { throw error }
        let now = Date()
        let used: Double = credential.accountHint == "B" ? 46 : (provider == .codex ? 21 : 58)
        let end = now.addingTimeInterval(300000)
        return UsageSnapshot(provider: provider.rawValue, title: provider.shortName,
            accountID: credential.accountHint, accountLabel: "Fixture", usedPercent: used,
            windowStart: end.addingTimeInterval(-604800), resetsAt: end, observedAt: now)
    }
    func fail(_ provider: QuotaProvider, error: LiveReadError?) { failures[provider] = error }
    func slow(_ account: String) { slowAccount = account }
    func count(_ provider: QuotaProvider) -> Int { calls[provider, default: 0] }
    func peak(_ provider: QuotaProvider) -> Int { peaks[provider, default: 0] }
}

@MainActor
private final class FixtureClock {
    var now = Date()
    func advance(_ interval: TimeInterval) { now.addTimeInterval(interval) }
}

@MainActor
final class LiveUsageModelTests: XCTestCase {
    func testIndependentRealProviderPipelineWithoutDemoFallback() async {
        let reader = FixtureReader(), client = FixtureClient()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false, stateStore: MemoryRefreshStateStore())
        await reader.fail(.fable, error: .loginExpired)
        await model.refresh()
        XCTAssertEqual(model.snapshots.map(\.remainingText), ["79%", "—"])
        XCTAssertEqual(model.issues["claude-fable"], "Login expired")
        XCTAssertNil(model.issues["codex"])
        let fableCalls = await client.count(.fable)
        XCTAssertEqual(fableCalls, 0)
    }

    func testLateOldAccountResponseNeverReplacesNewAccount() async throws {
        let reader = FixtureReader(), client = FixtureClient()
        await client.slow("A")
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false, stateStore: MemoryRefreshStateStore())
        let old = Task { await model.refreshProvider(.codex) }
        try await Task.sleep(nanoseconds: 40_000_000)
        await reader.select(.codex, account: "B")
        await model.refreshProvider(.codex)
        await old.value
        // The old request is drained before the new-account request starts.
        await model.refreshProvider(.codex)
        for _ in 0..<100 {
            if model.snapshots[0].accountID == "B", !model.isRefreshing { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let peak = await client.peak(.codex)
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(model.snapshots[0].accountID, "B")
        XCTAssertEqual(model.snapshots[0].remainingText, "54%")
        XCTAssertFalse(model.isRefreshing)
    }

    func testLogoutClearsOnlySelectedProvider() async {
        let reader = FixtureReader(), client = FixtureClient()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false, stateStore: MemoryRefreshStateStore())
        await model.refresh()
        await reader.fail(.codex, error: .notSignedIn)
        await model.auditCredentials()
        XCTAssertEqual(model.snapshots.map(\.remainingText), ["—", "42%"])
        XCTAssertEqual(model.snapshots[1].accountID, "C")
    }

    func testRateLimitHonorsBackoffAndKeepsRecentReadingQuiet() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
                                   stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await model.refreshProvider(.codex)
        time.advance(120)
        await client.fail(.codex, error: .rateLimited(300))
        await model.refreshProvider(.codex)
        await model.refreshProvider(.codex)
        let calls = await client.count(.codex)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.snapshots[0].remainingText, "79%")
        XCTAssertEqual(model.issues["codex"], "Rate limited") // diagnostic only
        let readout = MenuReadout(snapshot: model.snapshots[0], now: time.now, issue: model.issues["codex"])
        XCTAssertEqual(readout.usedLabel, "used")
        XCTAssertFalse(readout.summary.contains("Rate limited"))
    }

    func testTokenRenewalPreservesCooldownThenRecoversSameAccount() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
                                   stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await model.refreshProvider(.codex)
        time.advance(120)
        await client.fail(.codex, error: .rateLimited(300))
        await model.refreshProvider(.codex)
        await reader.select(.codex, account: "A", token: "synthetic-renewed")
        await client.fail(.codex, error: nil)
        await model.refreshProvider(.codex)
        var calls = await client.count(.codex)
        XCTAssertEqual(calls, 2)
        time.advance(300)
        await model.refreshProvider(.codex)
        calls = await client.count(.codex)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(model.snapshots[0].accountID, "A")
        XCTAssertEqual(model.snapshots[0].remainingText, "79%")
        XCTAssertNil(model.issues["codex"])
    }

    func testMissingWeekIsNotInventedFromAnotherQuota() async {
        let reader = FixtureReader(), client = FixtureClient()
        await client.fail(.fable, error: .missingWeekly)
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false, stateStore: MemoryRefreshStateStore())
        await model.refresh()
        XCTAssertEqual(model.snapshots[1].remainingText, "—")
        XCTAssertEqual(model.issues["claude-fable"], "Weekly limit unavailable")
    }

    func testEvidenceHasNoCredentialsOrAccountIdentifiers() async {
        let reader = FixtureReader(), client = FixtureClient()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false, stateStore: MemoryRefreshStateStore())
        await model.refresh()
        let data = try! JSONSerialization.data(withJSONObject: model.evidence(at: Date()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-A"))
        XCTAssertFalse(text.contains("accessToken"))
        XCTAssertFalse(text.contains("accountID"))
        XCTAssertTrue(text.contains("accountVerified"))
    }
    func testClaudeBurstDoesNotRefetchWithinPollingInterval() async {
        let reader = FixtureReader(), client = FixtureClient()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false, stateStore: MemoryRefreshStateStore())
        for _ in 0..<12 { await model.refreshProvider(.fable) }
        let calls = await client.count(.fable)
        XCTAssertEqual(calls, 1, "Opening the menu repeatedly must reuse the successful weekly reading")
    }

    func testClaudeTokenRenewalPreservesRateLimit() async {
        let reader = FixtureReader(), client = FixtureClient()
        await client.fail(.fable, error: .rateLimited(300))
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false, stateStore: MemoryRefreshStateStore())
        await model.refreshProvider(.fable)
        await reader.select(.fable, account: "C", token: "synthetic-renewed")
        await client.fail(.fable, error: nil)
        await model.refreshProvider(.fable)
        let calls = await client.count(.fable)
        XCTAssertEqual(calls, 1, "Token renewal must not erase a server-imposed wait")
        XCTAssertEqual(model.issues["claude-fable"], "Rate limited")
    }

    func testAllTriggersShareProviderCadences() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await model.refresh()
        for _ in 0..<5 { await model.refresh(); await model.auditCredentials(); model.refreshIfNeeded() }
        time.advance(120)
        await model.refresh()
        var codex = await client.count(.codex), claude = await client.count(.fable)
        XCTAssertEqual(codex, 2); XCTAssertEqual(claude, 1)
        time.advance(180)
        await model.refresh()
        codex = await client.count(.codex); claude = await client.count(.fable)
        XCTAssertEqual(codex, 3); XCTAssertEqual(claude, 2)
    }

    func testCooldownSurvivesModelRestartAndAccountSwitch() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let store = MemoryRefreshStateStore()
        await client.fail(.fable, error: .rateLimited(3600))
        let first = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: store, clock: { time.now })
        await first.refreshProvider(.fable)
        await reader.select(.fable, account: "B")
        let second = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: store, clock: { time.now })
        time.advance(3599)
        await second.refreshProvider(.fable)
        let count = await client.count(.fable)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(second.snapshots[1].remainingText, "—")
        time.advance(1)
        await client.fail(.fable, error: nil)
        await second.refreshProvider(.fable)
        XCTAssertEqual(second.snapshots[1].accountID, "B")
    }

    func testPassiveClaudeCacheUpdatesDuringCooldownWithoutHTTPOrRetimestamping() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let store = MemoryRefreshStateStore()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: store, clock: { time.now })
        await client.fail(.fable, error: .rateLimited(3600))
        await model.refreshProvider(.fable)
        time.advance(60)
        let captured = time.now.addingTimeInterval(-10), end = time.now.addingTimeInterval(100000)
        let cache = UsageSnapshot(provider: "claude-fable", title: "Claude", accountID: "C", accountLabel: "Fixture",
            usedPercent: 11, windowStart: end.addingTimeInterval(-604800), resetsAt: end, observedAt: captured,
            source: "claude-code-cache")
        await client.setCache(cache)
        await model.refreshProvider(.fable)
        let count = await client.count(.fable)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.snapshots[1].remainingText, "89%")
        XCTAssertEqual(model.snapshots[1].observedAt, captured)
        XCTAssertEqual(store.load(.fable)?.reason, .rateLimit)
        let readout = MenuReadout(snapshot: model.snapshots[1], now: time.now, issue: model.issues["claude-fable"])
        XCTAssertEqual(readout.usedLabel, "used")
        XCTAssertFalse(readout.summary.contains("Rate limited"))
    }

    func testSameAccountLastGoodReadingSurvivesRestartAndCooldown() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let store = MemoryRefreshStateStore()
        let first = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: store, clock: { time.now })
        await first.refreshProvider(.fable)
        let captured = first.snapshots[1].observedAt
        time.advance(300)
        await client.fail(.fable, error: .rateLimited(3600))
        await first.refreshProvider(.fable)
        let second = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: store, clock: { time.now })
        await second.refreshProvider(.fable)
        let count = await client.count(.fable)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(second.snapshots[1].remainingText, "42%")
        XCTAssertEqual(second.snapshots[1].observedAt, captured)
        XCTAssertEqual(second.issues["claude-fable"], "Rate limited")
    }

    func testEachProviderIsScheduledForTheMomentItsOwnGateReopens() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await model.refresh()
        let start = time.now
        XCTAssertEqual(model.scheduledAttempts[.codex], start.addingTimeInterval(120))
        XCTAssertEqual(model.scheduledAttempts[.fable], start.addingTimeInterval(300))
        // A shared tick a moment early fetches nothing and keeps each provider's own wake-up.
        time.advance(119.9)
        await model.refresh()
        var codex = await client.count(.codex)
        XCTAssertEqual(codex, 1)
        XCTAssertEqual(model.scheduledAttempts[.codex], start.addingTimeInterval(120))
        XCTAssertEqual(model.scheduledAttempts[.fable], start.addingTimeInterval(300))
        // The wake-up itself fetches, so no whole period is skipped, and it re-arms from there.
        time.now = start.addingTimeInterval(121)
        await model.refreshProvider(.codex)
        codex = await client.count(.codex)
        XCTAssertEqual(codex, 2)
        XCTAssertEqual(model.scheduledAttempts[.codex], time.now.addingTimeInterval(120))
        let claude = await client.count(.fable)
        XCTAssertEqual(claude, 1)
    }

    func testScheduledAttemptsFollowBackoffAndStopWhenSignedOut() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await client.fail(.fable, error: .rateLimited(900))
        await model.refresh()
        XCTAssertEqual(model.scheduledAttempts[.fable], time.now.addingTimeInterval(900))
        XCTAssertNotNil(model.scheduledAttempts[.codex])
        await reader.fail(.codex, error: .notSignedIn)
        time.advance(121)
        await model.refreshProvider(.codex)
        XCTAssertNil(model.scheduledAttempts[.codex], "A signed-out provider must not keep waking itself")
    }

    func testConnectionFailuresRetryInSecondsAndKeepTheLastKnownReading() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await model.refresh()
        time.advance(300)
        await client.fail(.codex, error: .network)
        await client.fail(.fable, error: .network)
        for _ in 0..<2 {
            await model.refresh()
            XCTAssertEqual(model.scheduledAttempts[.codex], time.now.addingTimeInterval(30))
            XCTAssertEqual(model.scheduledAttempts[.fable], time.now.addingTimeInterval(30))
            XCTAssertEqual(model.issues["claude-fable"], "Offline")
            XCTAssertEqual(model.snapshots.map(\.remainingText), ["79%", "42%"])
            time.advance(30)
        }
        await client.fail(.codex, error: nil)
        await client.fail(.fable, error: nil)
        await model.refresh()
        let codex = await client.count(.codex), claude = await client.count(.fable)
        XCTAssertEqual(codex, 4); XCTAssertEqual(claude, 4)
        XCTAssertNil(model.issues["claude-fable"])
        XCTAssertEqual(model.scheduledAttempts[.fable], time.now.addingTimeInterval(300))
    }

    func testSwitchingAccountDropsTheOldReadingAtOnceAndFetchesTheNewOne() async throws {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await model.refresh()
        XCTAssertEqual(model.snapshots.map(\.accountID), ["A", "C"])
        time.advance(10) // well inside both providers' normal spacing
        await reader.select(.codex, account: "B")
        await reader.select(.fable, account: "B")
        await model.auditCredentials()
        // The previous accounts' numbers are gone before the new account's reading arrives.
        XCTAssertFalse(model.snapshots.contains { $0.accountID == "A" || $0.accountID == "C" })
        let deadline = Date().addingTimeInterval(5)
        while model.snapshots.contains(where: { $0.accountID != "B" }), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.snapshots.map(\.accountID), ["B", "B"])
        XCTAssertEqual(model.snapshots.map(\.remainingText), ["54%", "54%"])
        // A new account does not wait out the previous account's normal spacing.
        let codex = await client.count(.codex), claude = await client.count(.fable)
        XCTAssertEqual(codex, 2); XCTAssertEqual(claude, 2)
    }

    func testAccountSwitchNoticeNamesTheNewAccountOnlyOnARealSwitch() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { time.now })
        var notices: [String] = []
        model.onAccountSwitch = { provider, email in notices.append("\(provider.rawValue) \(email ?? "-")") }
        await model.refresh()
        XCTAssertEqual(notices, [], "The first accounts after launch are not a switch")
        await reader.select(.codex, account: "A", token: "synthetic-renewed")
        await model.auditCredentials()
        XCTAssertEqual(notices, [], "Token renewal is not a switch")
        await reader.use(LiveCredential(provider: .codex, accessToken: "synthetic-B", accountHint: "B", accountEmail: "b@example.com"))
        await model.auditCredentials()
        XCTAssertEqual(notices, ["codex b@example.com"])
        // Signing out and into another account is still a switch; signing back into it is not.
        await reader.fail(.codex, error: .notSignedIn)
        await model.auditCredentials()
        await reader.use(LiveCredential(provider: .codex, accessToken: "synthetic-D", accountHint: "D", accountEmail: "d@example.com"))
        await model.auditCredentials()
        await model.auditCredentials()
        XCTAssertEqual(notices, ["codex b@example.com", "codex d@example.com"])
        // A Claude organization switch changes whose weekly limit is shown.
        await reader.use(LiveCredential(provider: .fable, accessToken: "synthetic-C", accountHint: "C",
                                        organizationHint: "org-2", accountEmail: "c@example.com"))
        await model.auditCredentials()
        XCTAssertEqual(notices.last, "claude-fable c@example.com")
        // A read without a real account identity never announces anything.
        await reader.use(LiveCredential(provider: .fable, accessToken: "synthetic-X", accountHint: nil))
        await model.auditCredentials()
        XCTAssertEqual(notices.count, 3)
    }

    func testClaudeSwitchWithoutKeychainAccessNeverShowsThePreviousAccount() async {
        let reader = FixtureReader(), client = FixtureClient(), time = FixtureClock()
        let model = LiveUsageModel(reader: reader, client: client, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { time.now })
        await model.refreshProvider(.fable)
        XCTAssertEqual(model.snapshots[1].accountID, "C")
        // Claude Code switched to D and rewrote its Keychain item: only D's identity is readable,
        // and no same-account Web session exists.
        await reader.use(LiveCredential(provider: .fable, accessToken: "", accountHint: "D",
                                        credentialIssue: .keychainPermission))
        await client.fail(.fable, error: .keychainPermission)
        time.advance(10)
        await model.refreshProvider(.fable)
        XCTAssertNil(model.snapshots[1].accountID)
        XCTAssertEqual(model.snapshots[1].remainingText, "—")
        XCTAssertEqual(model.issues["claude-fable"], "Keychain access needed")
    }

    func testAutomaticModelFetchesWhenTheGateReopensWithoutAnotherTrigger() async throws {
        let reader = FixtureReader(), client = FixtureClient(), store = MemoryRefreshStateStore()
        store.save(ProviderRefreshState(nextAttempt: Date().addingTimeInterval(0.3), reason: .polling,
                                        consecutiveRateLimits: 0), for: .codex)
        let model = LiveUsageModel(reader: reader, client: client, stateStore: store)
        let deadline = Date().addingTimeInterval(10)
        while model.scheduledAttempts[.codex] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var calls = await client.count(.codex)
        XCTAssertEqual(calls, 0, "The launch refresh must find the gate still closed")
        while calls == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            calls = await client.count(.codex)
        }
        XCTAssertEqual(calls, 1)
        let next = try XCTUnwrap(model.scheduledAttempts[.codex])
        XCTAssertEqual(next.timeIntervalSinceNow, 120, accuracy: 5)
    }

}
