import XCTest
import QuotaCore
@testable import QuotaMenu

final class MenuReadoutTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadoutClearlyMeansUsed() {
        let readout = MenuReadout(snapshot: DemoScenario.everyday.snapshots(at: now)[0], now: now)
        XCTAssertEqual(readout.used, "32%")
        XCTAssertEqual(readout.usedLabel, "used")
        XCTAssertNil(readout.unavailableText)
        XCTAssertTrue(readout.summary.contains("32% used"))
        XCTAssertEqual(readout.reset, "Resets in 3d")
        XCTAssertEqual(readout.pace, "Slow")
    }

    func testClaudeRowIsItsWeeklyLimit() {
        let readout = MenuReadout(snapshot: DemoScenario.everyday.snapshots(at: now)[1], now: now)
        XCTAssertEqual(readout.title, "Claude Code")
        XCTAssertEqual(readout.subtitle, "Weekly · Personal demo account")
        XCTAssertEqual(readout.used, "64%")
        XCTAssertEqual(readout.reset, "Resets in 3d 13h")
        XCTAssertEqual(readout.pace, "Fast")
    }

    func testTooltipContainsBothProvidersAndDemoBoundary() {
        let value = MenuReadout.tooltip(snapshots: DemoScenario.everyday.snapshots(at: now), now: now,
                                       status: "Demo data — no live accounts connected")
        XCTAssertTrue(value.contains("Codex: 32% used"))
        XCTAssertTrue(value.contains("Claude Code: 64% used"))
        XCTAssertTrue(value.contains("Weekly · Personal demo account"))
        XCTAssertFalse(value.contains("Fable"))
        XCTAssertTrue(value.contains("no live accounts connected"))
    }

    func testDisconnectedReadoutNeverInventsZeroOrResetDate() {
        let readout = MenuReadout(snapshot: DemoScenario.disconnected.snapshots(at: now)[1], now: now)
        XCTAssertEqual(readout.used, "—")
        XCTAssertEqual(readout.reset, "No usage data")
        XCTAssertEqual(readout.pace, "Not connected")
        XCTAssertEqual(readout.usedLabel, "")
        XCTAssertEqual(readout.unavailableText, "No usage data")
    }

    func testSignedOutHasOneUsefulStatusInsteadOfQuotaPlaceholders() {
        let readout = MenuReadout(snapshot: DemoScenario.disconnected.snapshots(at: now)[1],
                                  now: now, issue: "Sign in required")
        XCTAssertEqual(readout.unavailableText, "Sign in required")
        XCTAssertEqual(readout.usedLabel, "")
        XCTAssertNil(readout.usedFraction)
        XCTAssertFalse(readout.summary.contains("— used"))
        XCTAssertFalse(readout.summary.contains("No usage data"))
    }

    func testInlineFreshnessIsStillExplicitWithoutSecondLabelLine() {
        let snapshot = DemoScenario.everyday.snapshots(at: now)[0]
        let stale = MenuReadout(snapshot: snapshot, now: now.addingTimeInterval(301))
        XCTAssertEqual(stale.usedLabel, "last known")
        XCTAssertEqual(stale.pace, "Out of date")
        XCTAssertTrue(stale.summary.contains("Last known: 32% used"))
        let offline = MenuReadout(snapshot: snapshot, now: now, issue: "Offline")
        XCTAssertEqual(offline.usedLabel, "last known")
        XCTAssertEqual(offline.pace, "Offline")
        XCTAssertNil(offline.unavailableText)
    }

    func testAllUIReadoutsAndScenariosAreEnglish() {
        for scenario in DemoScenario.allCases {
            for alternate in [false, true] {
                let values = scenario.snapshots(at: now, alternateAccount: alternate)
                    .map { MenuReadout(snapshot: $0, now: now).summary } + [scenario.label]
                for text in values {
                    // Unicode Script_Extensions can classify the middle dot as Han.
                    // UI copy is ASCII English, allowing only these two typographic marks.
                    XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII || "—·".unicodeScalars.contains($0) })
                }
            }
        }
    }
    func testRateLimitIsQuietUntilReadingActuallyAges() {
        let snapshot = DemoScenario.everyday.snapshots(at: now)[1]
        let recent = MenuReadout(snapshot: snapshot, now: now.addingTimeInterval(899), issue: "Rate limited")
        XCTAssertEqual(recent.usedLabel, "used")
        XCTAssertEqual(recent.pace, snapshot.paceText(at: now.addingTimeInterval(899)))
        XCTAssertFalse(recent.summary.contains("Rate limited"))
        let delayed = MenuReadout(snapshot: snapshot, now: now.addingTimeInterval(901), issue: "Rate limited")
        XCTAssertEqual(delayed.usedLabel, "last known")
        XCTAssertEqual(delayed.pace, "Delayed")
        XCTAssertFalse(delayed.summary.contains("Rate limited"))
        let unknown = MenuReadout(snapshot: DemoScenario.disconnected.snapshots(at: now)[1], now: now, issue: "Rate limited")
        XCTAssertEqual(unknown.unavailableText, "Updating")
        XCTAssertNil(unknown.usedFraction)
    }

    func testClaudePollingBudgetDoesNotProduceRoutineStaleFlicker() {
        let snapshot = DemoScenario.everyday.snapshots(at: now)[1]
        XCTAssertEqual(MenuReadout(snapshot: snapshot, now: now.addingTimeInterval(360)).usedLabel, "used")
    }

}
