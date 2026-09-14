import Combine
import Foundation
import QuotaCore

@MainActor
final class DemoUsageModel: ObservableObject {
    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var scenario = DemoScenario.everyday
    @Published private(set) var statusText = "Demo data — no live accounts connected"
    @Published private(set) var isSwitching = false
    private var alternateProviders = Set<String>()
    private var caches = [SnapshotCache(), SnapshotCache()]

    init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1),
           let value = DemoScenario(rawValue: arguments[index + 1]) { scenario = value }
        refresh()
    }

    func refresh() {
        let now = Date()
        let primary = scenario.snapshots(at: now)
        let alternate = scenario.snapshots(at: now, alternateAccount: true)
        snapshots = primary.enumerated().map { index, value in
            alternateProviders.contains(value.provider) ? alternate[index] : value
        }
        for (index, value) in snapshots.enumerated() {
            caches[index].selectAccount(value.accountID)
            caches[index].accept(value)
        }
        statusText = "Demo data — no live accounts connected"
        writeEvidence()
    }

    func selectScenario(_ value: DemoScenario) {
        scenario = value
        refresh()
    }

    func swapAccount(provider: String) {
        guard !isSwitching, let index = snapshots.firstIndex(where: { $0.provider == provider }) else { return }
        isSwitching = true
        caches[index].selectAccount(nil)
        snapshots[index] = DemoScenario.disconnected.snapshots(at: Date())[index]
        statusText = "Demo account switch — updating"
        if alternateProviders.contains(provider) { alternateProviders.remove(provider) }
        else { alternateProviders.insert(provider) }
        writeEvidence()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.isSwitching = false
            self.refresh()
        }
    }

    private func writeEvidence() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--evidence"), arguments.indices.contains(index + 1) else { return }
        let now = Date()
        let record: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "presentation": "NSMenu + NSHostingView", "customDrawing": true, "uiLanguage": "en",
            "mode": "demo", "networkRequests": 0, "liveCredentialsAccessed": false,
            "scenario": scenario.rawValue, "isSwitching": isSwitching,
            "status": statusText,
            "snapshots": snapshots.map { ["provider": $0.provider, "account": $0.accountLabel,
                                          "remaining": $0.remainingText, "pace": $0.paceText(at: now),
                                          "reset": $0.resetText(at: now)] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
        }
    }
}
