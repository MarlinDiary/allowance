import Foundation
import QuotaCore
import XCTest
@testable import QuotaMenu

@MainActor
final class RefreshPolicyTests: XCTestCase {
    func testExponentialWaitRespectsLongerServerDelayAndResetsAfterSuccess() {
        let policy = RefreshPolicy(store: MemoryRefreshStateStore())
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        for expected in [300.0, 600, 1200, 1800, 1800] {
            policy.started(.fable, at: time)
            policy.failed(.fable, error: .rateLimited(60), at: time)
            XCTAssertEqual(policy.state(.fable)!.nextAttempt.timeIntervalSince(time), expected)
            XCTAssertFalse(policy.mayAttempt(.fable, at: time.addingTimeInterval(expected - 1)))
            time.addTimeInterval(expected)
            XCTAssertTrue(policy.mayAttempt(.fable, at: time))
        }
        policy.started(.fable, at: time)
        policy.failed(.fable, error: .rateLimited(7200), at: time)
        XCTAssertEqual(policy.state(.fable)!.nextAttempt.timeIntervalSince(time), 7200)
        policy.succeeded(.fable, at: time)
        XCTAssertEqual(policy.state(.fable)!.consecutiveRateLimits, 0)
    }
    func testDiskCooldownSurvivesStoreRecreationWithoutCredentials() throws {
        let name = "quota-refresh-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = RefreshPolicy(store: DefaultsRefreshStateStore(defaults: defaults))
        let time = Date()
        first.failed(.fable, error: .rateLimited(3600), at: time)
        let second = RefreshPolicy(store: DefaultsRefreshStateStore(defaults: defaults))
        second.credentialsChanged(.fable, accountChanged: true)
        XCTAssertFalse(second.mayAttempt(.fable, at: time.addingTimeInterval(3599)))
        XCTAssertEqual(first.state(.fable), second.state(.fable))
        let encoded = try JSONEncoder().encode(second.state(.fable))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("account"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("token"))
    }
    func testRetryAfterSecondsDateMalformedAndNonFinite() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (raw, expected) in [("3600", 3600.0), ("Fri, 15 Jan 2027 09:00:00 GMT", 3600),
                                ("bad", 300), ("nan", 300), ("-20", 60)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": raw]))
            XCTAssertThrowsError(try UsageHTTPStatus.check(response, at: now)) { error in
                XCTAssertEqual(error as? LiveReadError, .rateLimited(expected))
            }
        }
    }
    func testConnectionFailureRetriesSoonWhileServerAnswersKeepTheirWait() {
        let policy = RefreshPolicy(store: MemoryRefreshStateStore())
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        for provider in QuotaProvider.allCases {
            policy.started(provider, at: time)
            policy.failed(provider, error: .network, at: time)
            XCTAssertEqual(policy.state(provider)!.nextAttempt.timeIntervalSince(time), 30)
            XCTAssertFalse(policy.mayAttempt(provider, at: time.addingTimeInterval(29)))
            for answered in [LiveReadError.http(503), .invalidResponse, .missingWeekly] {
                policy.failed(provider, error: answered, at: time)
                XCTAssertEqual(policy.state(provider)!.nextAttempt.timeIntervalSince(time), RefreshPolicy.interval(provider))
            }
        }
        // A connection failure between two 429s neither shortens nor resets the backoff.
        var now = time
        policy.failed(.fable, error: .rateLimited(60), at: now)
        now.addTimeInterval(300)
        policy.started(.fable, at: now)
        policy.failed(.fable, error: .network, at: now)
        XCTAssertEqual(policy.state(.fable)!.consecutiveRateLimits, 1)
        now.addTimeInterval(30)
        policy.started(.fable, at: now)
        policy.failed(.fable, error: .rateLimited(60), at: now)
        XCTAssertEqual(policy.state(.fable)!.nextAttempt.timeIntervalSince(now), 600)
    }
    func testOldFableReadingIsNeverRestoredAsTheWeeklyOne() throws {
        let name = "quota-usage-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        let credential = LiveCredential(provider: .fable, accessToken: "synthetic", accountHint: "C")
        func reading(_ used: Double, title: String) -> UsageSnapshot {
            UsageSnapshot(provider: "claude-fable", title: title, accountID: "C", accountLabel: "Fixture",
                          usedPercent: used, windowStart: nil, resetsAt: now.addingTimeInterval(86400), observedAt: now)
        }
        let stored = StoredProviderUsage(ownerDigest: StoredProviderUsage.digest(credential), snapshot: reading(14, title: "Fable"))
        defaults.set(try JSONEncoder().encode(stored), forKey: "quota.usage.v1.claude-fable")
        let policy = RefreshPolicy(store: DefaultsRefreshStateStore(defaults: defaults))
        XCTAssertNil(policy.restore(.fable, credential: credential, at: now), "A stored Fable percentage is not the weekly one")
        policy.capture(reading(31, title: "Claude"), credential: credential)
        XCTAssertEqual(policy.restore(.fable, credential: credential, at: now)?.usedPercent, 31)
        XCTAssertNotNil(defaults.data(forKey: "quota.usage.v2.claude-fable"))
        XCTAssertEqual(DefaultsRefreshStateStore.usageKey(.codex), "quota.usage.v1.codex", "Codex readings survive the upgrade")
    }
    func testUsageRequestsWaitBoundedlyForConnectivityInsteadOfFailingOffline() {
        let config = NativeUsageHTTPClient.configuration()
        XCTAssertTrue(config.waitsForConnectivity)
        XCTAssertEqual(config.timeoutIntervalForResource, 25)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCache)
    }
}
