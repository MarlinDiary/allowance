import Foundation
import QuotaCore
import XCTest
@testable import QuotaMenu

private actor HeaderCheckingHTTP: UsageHTTPClient {
    func response(for request: URLRequest) -> (Data, HTTPURLResponse) {
        XCTAssertEqual(request.url?.host, "chatgpt.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), RequestIdentity.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "fixture-account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let body = """
        {"account_id":"fixture-account","rate_limit":{"secondary_window":{"used_percent":25,"limit_window_seconds":604800,"reset_at":\(Date().addingTimeInterval(604800).timeIntervalSince1970)}}}
        """
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class RequestIdentityTests: XCTestCase {
    func testVersionIsNotHardcoded() {
        XCTAssertEqual(RequestIdentity.userAgent(version: "0.6.16"), "Allowance/0.6.16")
        XCTAssertEqual(RequestIdentity.userAgent(version: "2.4.0"), "Allowance/2.4.0")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(RequestIdentity.userAgent, RequestIdentity.userAgent(version: version))
    }

    func testMissingOrUnsafeVersionsUseProductNameOnly() {
        for version in [nil, "", "1.0\r\nCookie: injected", "1 0", "版本", String(repeating: "1", count: 65)] as [String?] {
            XCTAssertEqual(RequestIdentity.userAgent(version: version), "Allowance")
        }
    }

    func testResetRequestPreservesConditionalPollingWithoutCredentials() {
        let request = ResetMonitor.statusRequest(etag: "\"fixture-etag\"")
        XCTAssertEqual(request.url?.absoluteString, "https://codex-resets.com/api/v1/status")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), RequestIdentity.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"fixture-etag\"")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(ResetMonitor.statusRequest(etag: nil).value(forHTTPHeaderField: "If-None-Match"))
    }

    func testCodexRequestUsesSharedIdentityAndKeepsAccountHeaders() async throws {
        let transport = LiveUsageTransport(http: HeaderCheckingHTTP())
        let value = try await transport.fetch(.codex, credential: LiveCredential(provider: .codex,
            accessToken: "fixture-token", accountHint: "fixture-account"))
        XCTAssertEqual(value.remainingText, "75%")
    }
}
