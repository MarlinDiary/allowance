import Foundation
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
}
