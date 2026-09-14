import XCTest
import QuotaCore
@testable import QuotaMenu

@MainActor
final class DemoUsageModelTests: XCTestCase {
    func testDefaultClearlyUsesDemoData() {
        let model = DemoUsageModel()
        XCTAssertEqual(model.snapshots.map(\.remainingText), ["68%", "36%"])
        XCTAssertTrue(model.statusText.contains("Demo data"))
        XCTAssertTrue(model.statusText.contains("no live accounts connected"))
    }

    func testCodexSwitchIsIndependent() async throws {
        let model = DemoUsageModel()
        let fableID = model.snapshots[1].accountID
        model.swapAccount(provider: "codex")
        XCTAssertNil(model.snapshots[0].remainingFraction)
        XCTAssertEqual(model.snapshots[1].accountID, fableID)
        XCTAssertEqual(model.snapshots[1].remainingText, "36%")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.isSwitching)
        XCTAssertEqual(model.snapshots.map(\.remainingText), ["54%", "36%"])
        XCTAssertEqual(model.snapshots[1].accountID, fableID)
    }

    func testFableSwitchIsIndependent() async throws {
        let model = DemoUsageModel()
        let codexID = model.snapshots[0].accountID
        model.swapAccount(provider: "claude-fable")
        XCTAssertEqual(model.snapshots[0].accountID, codexID)
        XCTAssertNil(model.snapshots[1].remainingFraction)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.snapshots.map(\.remainingText), ["68%", "78%"])
        XCTAssertEqual(model.snapshots[0].accountID, codexID)
    }

    func testDisconnectedScenarioIsNotZero() {
        let model = DemoUsageModel()
        model.selectScenario(.disconnected)
        XCTAssertEqual(model.snapshots.map(\.remainingText), ["—", "—"])
        XCTAssertTrue(model.snapshots.allSatisfy { $0.accountID == nil })
    }
}
