import XCTest
@testable import QuotaCore

final class UsageSnapshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(used: Double?, account: String? = "A", elapsed: Double = 0.4) -> UsageSnapshot {
        let duration: TimeInterval = 604800
        return UsageSnapshot(provider: "codex", title: "Codex", accountID: account, accountLabel: "Demo",
                             usedPercent: used, windowStart: now.addingTimeInterval(-duration * elapsed),
                             resetsAt: now.addingTimeInterval(duration * (1 - elapsed)), observedAt: now)
    }
    func testRemainingUsesComplement() { XCTAssertEqual(snapshot(used: 32).remainingText, "68%") }
    func testUnknownIsNotZero() { XCTAssertEqual(snapshot(used: nil).remainingText, "—") }
    func testNonFiniteIsUnknown() { XCTAssertNil(snapshot(used: .nan).remainingFraction); XCTAssertNil(snapshot(used: .infinity).remainingFraction) }
    func testBoundsAreClamped() { XCTAssertEqual(snapshot(used: -5).remainingText, "100%"); XCTAssertEqual(snapshot(used: 120).remainingText, "0%") }
    func testFastComparesAgainstElapsedTime() { XCTAssertEqual(snapshot(used: 60).paceDelta(at: now)!, 0.2, accuracy: 0.0001); XCTAssertEqual(snapshot(used: 60).paceText(at: now), "Fast") }
    func testComfortablePace() { XCTAssertEqual(snapshot(used: 25).paceText(at: now), "Slow") }
    func testBalancedTolerance() { XCTAssertEqual(snapshot(used: 42).paceText(at: now), "Steady") }
    func testApprovedWordsCompareUsageWithTimeAndPreserveTolerance() {
        for (used, word) in [(20.0, "Slow"), (40.0, "Steady"), (60.0, "Fast"), (35.1, "Steady"), (44.9, "Steady")] {
            XCTAssertEqual(snapshot(used: used, elapsed: 0.4).paceText(at: now), word)
        }
    }
    func testExhaustionOverridesPace() { XCTAssertEqual(snapshot(used: 100).paceText(at: now), "Limit reached") }
    func testPassedResetIsNotTreatedAsAReset() { let value = snapshot(used: 60, elapsed: 1.1); XCTAssertNil(value.paceDelta(at: now)); XCTAssertEqual(value.resetText(at: now), "Awaiting usage update") }
    func testResetDescription() { XCTAssertEqual(snapshot(used: 60).resetText(at: now), "Resets in 4d 4h") }
    func testStaleBoundary() { XCTAssertFalse(snapshot(used: 20).isStale(at: now.addingTimeInterval(300))); XCTAssertTrue(snapshot(used: 20).isStale(at: now.addingTimeInterval(301))) }
    func testChangingAccountClearsOldUsage() {
        var cache = SnapshotCache(); cache.selectAccount("A"); XCTAssertTrue(cache.accept(snapshot(used: 32)))
        cache.selectAccount("B"); XCTAssertNil(cache.snapshot)
        XCTAssertFalse(cache.accept(snapshot(used: 32))); XCTAssertNil(cache.snapshot)
        XCTAssertTrue(cache.accept(snapshot(used: 22, account: "B"))); XCTAssertEqual(cache.snapshot?.remainingText, "78%")
    }
    func testSameAccountTokenRenewalPreservesSnapshot() {
        var cache = SnapshotCache(); cache.selectAccount("A"); cache.accept(snapshot(used: 32))
        cache.selectAccount("A"); XCTAssertEqual(cache.snapshot?.remainingText, "68%")
    }
    func testLogoutClearsOldUsage() {
        var cache = SnapshotCache(); cache.selectAccount("A"); cache.accept(snapshot(used: 32))
        cache.selectAccount(nil); XCTAssertNil(cache.snapshot); XCTAssertFalse(cache.accept(snapshot(used: nil, account: nil)))
    }
    func testAllDemoModesHaveTwoProviders() {
        for mode in DemoScenario.allCases {
            let rows = mode.snapshots(at: now)
            XCTAssertEqual(rows.map(\.provider), ["codex", "claude-fable"])
            if mode == .disconnected { XCTAssertEqual(rows.map(\.remainingText), ["—", "—"]) }
        }
    }
    func testFableDenominatorIsItsOwnLimit() { XCTAssertEqual(snapshot(used: 64).remainingText, "36%") }
}
