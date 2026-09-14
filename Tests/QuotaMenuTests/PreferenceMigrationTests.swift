import Foundation
import XCTest
@testable import QuotaMenu

final class PreferenceMigrationTests: XCTestCase {
    func testOnlyOwnedValidValuesMigrateAndExistingWins() {
        let name = "allowance.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let old = Data("{\"value\":1}".utf8), newer = Data("{\"value\":2}".utf8)
        defaults.set(newer, forKey: PreferenceMigration.ownedKeys[0])
        PreferenceMigration.migrate(from: [PreferenceMigration.ownedKeys[0]: old,
            PreferenceMigration.ownedKeys[1]: old, PreferenceMigration.ownedKeys[2]: "not data",
            PreferenceMigration.ownedKeys[3]: Data("invalid".utf8), "unrelated": old], to: defaults)
        XCTAssertEqual(defaults.data(forKey: PreferenceMigration.ownedKeys[0]), newer)
        XCTAssertEqual(defaults.data(forKey: PreferenceMigration.ownedKeys[1]), old)
        XCTAssertNil(defaults.object(forKey: PreferenceMigration.ownedKeys[2]))
        XCTAssertNil(defaults.object(forKey: PreferenceMigration.ownedKeys[3]))
        XCTAssertNil(defaults.object(forKey: "unrelated"))
    }
    func testFeedRetryAfterHandlesSecondsHTTPDateAndInvalid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ResetMonitor.retryAfter("600", now: now), 600)
        XCTAssertNil(ResetMonitor.retryAfter("nan", now: now))
        XCTAssertNil(ResetMonitor.retryAfter("-1", now: now))
        XCTAssertEqual(ResetMonitor.retryAfter("Fri, 15 Jan 2027 08:10:00 GMT", now: now), 600)
    }
}
