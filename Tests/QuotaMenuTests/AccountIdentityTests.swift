import Foundation
import XCTest
@testable import QuotaMenu

final class AccountIdentityTests: XCTestCase {
    private func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testCodexEmailComesFromItsOwnIDTokenClaims() {
        let token = base64URL(#"{"alg":"none"}"#) + "." + base64URL(#"{"email":"b@example.com","sub":"user?>~"}"#) + ".signature"
        XCTAssertEqual(LiveCredential.email(fromIDToken: token), "b@example.com")
        for malformed in ["", "one.two", "a.!!!.c", "a." + base64URL("[1]") + ".c", "a..c"] {
            XCTAssertNil(LiveCredential.email(fromIDToken: malformed), malformed)
        }
    }

    func testDisplayEmailIsTrimmedAndRejectsAnythingThatIsNotAnAddress() {
        XCTAssertEqual(LiveCredential.displayEmail("  b@example.com \n"), "b@example.com")
        XCTAssertNil(LiveCredential.displayEmail("no-at-sign"))
        XCTAssertNil(LiveCredential.displayEmail("a@b\nInjected line"))
        XCTAssertNil(LiveCredential.displayEmail(String(repeating: "a", count: 250) + "@x.com"))
        let credential = LiveCredential(provider: .codex, accessToken: "t", accountHint: "A", accountEmail: "not an email")
        XCTAssertNil(credential.accountEmail)
    }

    func testClaudeIdentityFollowsTheOrganizationWhoseWeeklyLimitItIs() {
        let personal = LiveCredential(provider: .fable, accessToken: "t", accountHint: "C", organizationHint: "org-1")
        let team = LiveCredential(provider: .fable, accessToken: "t", accountHint: "C", organizationHint: "org-2")
        XCTAssertNotEqual(personal.identity, team.identity)
        XCTAssertEqual(LiveCredential(provider: .codex, accessToken: "t", accountHint: "A").identity, "A")
        let unknown = LiveCredential(provider: .fable, accessToken: "t", accountHint: nil)
        XCTAssertEqual(unknown.identity, unknown.tokenFingerprint)
    }

    func testClaudeContextCarriesTheSignedInEmail() throws {
        let file = Data(#"{"oauthAccount":{"accountUuid":"C","organizationUuid":"org-1","emailAddress":"c@example.com"}}"#.utf8)
        let context = try XCTUnwrap(ClaudeAccountContext.parse(file))
        XCTAssertEqual(context.account, "C")
        XCTAssertEqual(context.organization, "org-1")
        XCTAssertEqual(context.email, "c@example.com")
        XCTAssertNil(ClaudeAccountContext.parse(Data(#"{"oauthAccount":{"emailAddress":"c@example.com"}}"#.utf8)))
    }

    func testSwitchNoticeNamesTheProviderAndTheNewAccountInEnglish() {
        let codex = AccountSwitchNotice.content(for: .codex, email: "b@example.com")
        XCTAssertEqual(codex.title, "Codex account switched")
        XCTAssertEqual(codex.body, "Allowance now shows usage for b@example.com.")
        let claude = AccountSwitchNotice.content(for: .fable, email: nil)
        XCTAssertEqual(claude.title, "Claude Code account switched")
        XCTAssertEqual(claude.body, "Allowance now shows usage for the new account.")
    }
}
