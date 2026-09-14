import CommonCrypto
import Foundation
import QuotaCore
import SQLite3
import XCTest
@testable import QuotaMenu

private let account = "00000000-0000-0000-0000-000000000001"
private let organization = "00000000-0000-0000-0000-000000000002"
private let credential = LiveCredential(provider: .fable, accessToken: "synthetic-token", accountHint: account, organizationHint: organization)
private func usage(_ used: Int = 26, end: Date = Date().addingTimeInterval(100000)) -> String {
    let date = ISO8601DateFormatter().string(from: end)
    return """
    {"seven_day":{"utilization":99},"limits":[{"kind":"weekly_scoped","percent":\(used),"resets_at":"\(date)","scope":{"model":{"display_name":"Fable"}}}]}
    """
}
private struct Step: Sendable {
    let host: String
    let path: String
    let status: Int
    let body: String
    var headers: [String: String] = [:]
}
private actor ScriptedHTTP: UsageHTTPClient {
    var steps: [Step]
    var calls = 0
    init(_ steps: [Step]) { self.steps = steps }
    func response(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        calls += 1
        guard !steps.isEmpty else { XCTFail("Unexpected extra request"); throw LiveReadError.network }
        let step = steps.removeFirst()
        XCTAssertEqual(request.url?.host, step.host); XCTAssertEqual(request.url?.path, step.path)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), version.map { "Allowance/" + $0 } ?? "Allowance")
        if step.host == "claude.ai" {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Cookie"))
        } else {
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        return (Data(step.body.utf8), HTTPURLResponse(url: request.url!, statusCode: step.status,
            httpVersion: nil, headerFields: step.headers)!)
    }
    func count() -> Int { calls }
}
private struct Sessions: ClaudeWebSessionReading {
    func read() async -> [ClaudeWebSession] { [ClaudeWebSession(key: "sk-ant-synthetic-session", source: "fixture")] }
}
private struct NoCache: ClaudeUsageCacheReading {
    func read(for credential: LiveCredential, at now: Date) async -> UsageSnapshot? { nil }
}
private struct OneCredential: CredentialReading {
    func read(_ provider: QuotaProvider, allowInteraction: Bool) async throws -> LiveCredential { credential }
}
@MainActor
final class ClaudeDataPathTests: XCTestCase {
    private func webSteps() -> [Step] {
        [Step(host: "claude.ai", path: "/api/account", status: 200, body: "{\"uuid\":\"\(account)\"}"),
         Step(host: "claude.ai", path: "/api/organizations", status: 200, body: "[{\"uuid\":\"\(organization)\"}]"),
         Step(host: "claude.ai", path: "/api/organizations/\(organization)/usage", status: 200, body: usage())]
    }
    func testOAuthServerFailureFallsBackToSameAccountWebAndFableOnly() async throws {
        let http = ScriptedHTTP([
            Step(host: "api.anthropic.com", path: "/api/oauth/profile", status: 200, body: "{\"account\":{\"uuid\":\"\(account)\"}}"),
            Step(host: "api.anthropic.com", path: "/api/oauth/usage", status: 503, body: "{}")] + webSteps())
        let transport = LiveUsageTransport(http: http, cache: NoCache(), webSessions: Sessions())
        let value = try await transport.fetch(.fable, credential: credential)
        XCTAssertEqual(value.remainingText, "74%")
        XCTAssertEqual(value.source, "web:fixture")
        XCTAssertEqual(value.accountID, account)
        let count = await http.count(); XCTAssertEqual(count, 5)
    }
    func test429WaitsBeforeTryingAnotherNetworkPath() async {
        let http = ScriptedHTTP([Step(host: "api.anthropic.com", path: "/api/oauth/profile", status: 429,
                                     body: "{}", headers: ["Retry-After": "300"])] + webSteps())
        let transport = LiveUsageTransport(http: http, cache: NoCache(), webSessions: Sessions())
        var now = Date()
        let model = LiveUsageModel(reader: OneCredential(), client: transport, startAutomatically: false,
            stateStore: MemoryRefreshStateStore(), clock: { now })
        await model.refreshProvider(.fable)
        await model.refreshProvider(.fable)
        var count = await http.count(); XCTAssertEqual(count, 1)
        now.addTimeInterval(300)
        await model.refreshProvider(.fable)
        count = await http.count(); XCTAssertEqual(count, 4)
        XCTAssertEqual(model.snapshots[1].remainingText, "74%")
        XCTAssertNil(model.issues["claude-fable"])
    }
    func testWrongBrowserAccountNeverRequestsItsUsage() async {
        let http = ScriptedHTTP([Step(host: "claude.ai", path: "/api/account", status: 200, body: "{\"uuid\":\"another-account\"}")])
        let transport = LiveUsageTransport(http: http, cache: NoCache(), webSessions: Sessions())
        let expired = LiveCredential(provider: .fable, accessToken: "", accountHint: account,
            organizationHint: organization, credentialIssue: .loginExpired)
        do { _ = try await transport.fetch(.fable, credential: expired); XCTFail("Must reject other account") }
        catch { XCTAssertEqual(error as? LiveReadError, .loginExpired) }
        let count = await http.count(); XCTAssertEqual(count, 1)
    }
    func testWrongOrganizationNeverRequestsUsage() async {
        let http = ScriptedHTTP([
            Step(host: "claude.ai", path: "/api/account", status: 200, body: "{\"uuid\":\"\(account)\"}"),
            Step(host: "claude.ai", path: "/api/organizations", status: 200, body: "[{\"uuid\":\"another-org\"}]")])
        let transport = LiveUsageTransport(http: http, cache: NoCache(), webSessions: Sessions())
        let expired = LiveCredential(provider: .fable, accessToken: "", accountHint: account,
            organizationHint: organization, credentialIssue: .loginExpired)
        do { _ = try await transport.fetch(.fable, credential: expired); XCTFail("Must reject other organization") }
        catch { XCTAssertEqual(error as? LiveReadError, .loginExpired) }
        let count = await http.count(); XCTAssertEqual(count, 2)
    }
    func testWeb429DoesNotStartOAuthOrNextBrowser() async {
        let http = ScriptedHTTP([Step(host: "claude.ai", path: "/api/account", status: 429,
            body: "{}", headers: ["Retry-After": "3600"])])
        let transport = LiveUsageTransport(http: http, cache: NoCache(), webSessions: Sessions())
        let expired = LiveCredential(provider: .fable, accessToken: "", accountHint: account,
            organizationHint: organization, credentialIssue: .loginExpired)
        do { _ = try await transport.fetch(.fable, credential: expired); XCTFail("Expected cooldown") }
        catch { XCTAssertEqual(error as? LiveReadError, .rateLimited(3600)) }
        let count = await http.count(); XCTAssertEqual(count, 1)
    }
    func testCacheKeepsOriginalTimestampRejectsOldOtherAccountAndSharedOnly() throws {
        let now = Date(), captured = now.addingTimeInterval(-60)
        func cache(account owner: String, timestamp: Date, payload: String) -> Data {
            Data("{\"cachedUsageUtilization\":{\"accountUuid\":\"\(owner)\",\"fetchedAtMs\":\(timestamp.timeIntervalSince1970 * 1000),\"utilization\":\(payload)}}".utf8)
        }
        let snapshot = try XCTUnwrap(ClaudeLocalUsageCache.decode(cache(account: account, timestamp: captured, payload: usage()), expectedAccount: account, at: now))
        XCTAssertEqual(snapshot.observedAt.timeIntervalSince1970, captured.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.remainingText, "74%")
        XCTAssertEqual(snapshot.source, "claude-code-cache")
        XCTAssertNil(ClaudeLocalUsageCache.decode(cache(account: "other", timestamp: captured, payload: usage()), expectedAccount: account, at: now))
        XCTAssertNil(ClaudeLocalUsageCache.decode(cache(account: account, timestamp: now.addingTimeInterval(-901), payload: usage()), expectedAccount: account, at: now))
        XCTAssertNil(ClaudeLocalUsageCache.decode(cache(account: account, timestamp: now.addingTimeInterval(1), payload: usage()), expectedAccount: account, at: now))
        XCTAssertNil(ClaudeLocalUsageCache.decode(cache(account: account, timestamp: captured, payload: "{\"seven_day\":{\"utilization\":99}}"), expectedAccount: account, at: now))
        XCTAssertNil(ClaudeLocalUsageCache.decode(cache(account: account, timestamp: captured, payload: usage(end: now.addingTimeInterval(-1))), expectedAccount: account, at: now))
    }
    func testCookieHeaderRejectsInjection() {
        XCTAssertFalse(NativeClaudeWebSessions.valid("sk-ant-value\r\nAuthorization: injected"))
        XCTAssertFalse(NativeClaudeWebSessions.valid("sk-ant-a; other=value"))
        XCTAssertTrue(NativeClaudeWebSessions.valid("sk-ant-synthetic-session"))
    }
    func testPreferredWebChallengeDoesNotTrapAutoOrRetryWebTwice() async throws {
        let http = ScriptedHTTP([
            Step(host: "claude.ai", path: "/api/account", status: 403, body: "challenge"),
            Step(host: "api.anthropic.com", path: "/api/oauth/profile", status: 200, body: "{\"account\":{\"uuid\":\"\(account)\"}}"),
            Step(host: "api.anthropic.com", path: "/api/oauth/usage", status: 200, body: usage())])
        let transport = LiveUsageTransport(http: http, cache: NoCache(), webSessions: Sessions(), preferWeb: true)
        let result = try await transport.fetch(.fable, credential: credential)
        XCTAssertEqual(result.source, "oauth")
        XCTAssertEqual(result.remainingText, "74%")
        let count = await http.count(); XCTAssertEqual(count, 3)
    }

}
