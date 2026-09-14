import AppKit
import Darwin
import Foundation
import QuotaCore

@main
enum EntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--reset-check") {
            Task { @MainActor in
                let monitor = ResetMonitor(onConfirmed: {})
                await monitor.poll()
                if let i = CommandLine.arguments.firstIndex(of: "--reset-check"), CommandLine.arguments.indices.contains(i + 1) {
                    await monitor.writeEvidence(to: CommandLine.arguments[i + 1])
                }
                monitor.stop()
                exit(monitor.lastHTTPStatus == 200 || monitor.lastHTTPStatus == 304 ? 0 : 1)
            }
            RunLoop.main.run()
        } else if CommandLine.arguments.contains("--source-check") {
            Task { @MainActor in
                let credential = try? await SystemCredentialReader().read(.fable, allowInteraction: false)
                let local: UsageSnapshot?
                if let credential { local = await ClaudeLocalUsageCache().read(for: credential, at: Date()) }
                else { local = nil }
                let sessions = await NativeClaudeWebSessions().read()
                let record: [String: Any] = ["mode": "source-readiness", "networkRequests": 0,
                    "activeAccountHintAvailable": credential?.accountHint != nil,
                    "oauthCredentialReadable": credential.map { !$0.accessToken.isEmpty } ?? false,
                    "localCacheHasFreshFable": local != nil,
                    "webSessionSources": sessions.map(\.source)]
                let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(0)
            }
            RunLoop.main.run()
        } else if CommandLine.arguments.contains("--live-check") {
            Task { @MainActor in
                let transport = LiveUsageTransport(preferWeb: CommandLine.arguments.contains("--prefer-claude-web"))
                let model = LiveUsageModel(client: transport, startAutomatically: false)
                await model.refresh()
                if let data = try? JSONSerialization.data(withJSONObject: model.evidence(at: Date()), options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                    exit(0)
                }
                exit(1)
            }
            RunLoop.main.run()
        } else if CommandLine.arguments.contains("--self-check") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let snapshots = DemoScenario.everyday.snapshots(at: now)
            let result: [String: Any] = [
                "mode": "fixture-check", "runtimeDefault": "live", "nativeFramework": "AppKit + SwiftUI",
                "presentation": "NSMenu + NSHostingView", "minimumMacOS": "13.0", "uiLanguage": "en",
                "customViews": true, "customDrawing": true, "customPanel": false,
                "liveCredentialsAccessed": false, "networkRequests": 0,
                "remaining": snapshots.map(\.remainingText),
                "progressStyle": "SwiftUI.Capsule.readOnly.4pt", "progressMeaning": "filled = used; empty = remaining",
                "progressValues": snapshots.compactMap(\.remainingFraction).map { 1 - $0 },
                "informationWidth": MenuMetrics.width, "informationHeight": MenuMetrics.informationHeight,
                "visibleAccountSubtitle": false,
                "quotaLabelPlacement": "inline",
                "remainingLabels": snapshots.map { MenuReadout(snapshot: $0, now: now).remainingLabel },
                "statusImageScaling": MenuMetrics.statusImageScaling == .scaleNone ? "none" : "scaled",
                "statusIconSize": MenuMetrics.statusIcon().size.width,
                "providerArtwork": ProviderBrand.allCases.map { $0.resourceURL.lastPathComponent },
                "providerImagesDecoded": ProviderBrand.allCases.allSatisfy { $0.image.isValid },
                "providerArtworkTemplate": ProviderBrand.allCases.allSatisfy { $0.image.isTemplate },
                "providerArtworkDarkColor": "white",
                "pace": snapshots.map { $0.paceText(at: now) },
                "unknown": DemoScenario.disconnected.snapshots(at: now).map(\.remainingText),
                "tooltip": MenuReadout.tooltip(snapshots: snapshots, now: now,
                                               status: "Demo data — no live accounts connected")
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Self-check failed: \(error)\n", stderr)
                exit(1)
            }
        } else {
            if let id = Bundle.main.bundleIdentifier,
               NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                print("Allowance is already running."); return
            }
            let app = NSApplication.shared
            PreferenceMigration.migratePreviousApp()
            let delegate = MenuAppDelegate()
            app.setActivationPolicy(.accessory)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
