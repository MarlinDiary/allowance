import Foundation
import XCTest
@testable import QuotaMenu

final class KeychainAccessTests: XCTestCase {
    func testLoginKeychainPromptsCanBeSuppressed() {
        // Without this switch the login keychain prompts from background reads, and an
        // unanswered prompt once stopped every refresh for eight hours.
        XCTAssertTrue(KeychainAccess.suppressesLegacyPrompts)
    }

    func testBackgroundReadsFailFastWithoutReturningData() async {
        let service = "dev.marlindiary.Allowance.tests.missing-" + UUID().uuidString
        let started = Date()
        async let first = KeychainAccess.password(service: service, allowInteraction: false)
        async let second = KeychainAccess.password(service: service, account: "nobody", allowInteraction: false)
        let results = await [first, second]
        for result in results {
            if case .success = result { XCTFail("A missing item must not read as data") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
