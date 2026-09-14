import AppKit
import Combine
import QuotaCore
import SwiftUI

@MainActor
final class MenuAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = LiveUsageModel()
    private let menu = NSMenu(title: "Allowance")
    private var statusItem: NSStatusItem?
    private var informationItems: [NSMenuItem] = []
    private var subscription: AnyCancellable?
    private var observation: CredentialObservation?
    private var menuIsOpen = false
    private var resetMonitor: ResetMonitor?
    private var shortcutTestTimer: Timer?
    private var shortcutTestPath: String?
    private var shortcutTestDispatched = false
    private var shortcutTestMenuWasOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.minimumWidth = MenuMetrics.width
        menu.delegate = self
        for snapshot in model.snapshots {
            let readout = MenuReadout(snapshot: snapshot, now: Date(), issue: model.issues[snapshot.provider])
            let item = NSMenuItem(title: readout.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            let host = NSHostingView(rootView: UsageInformationView(readout: readout))
            host.setFrameSize(NSSize(width: MenuMetrics.width, height: MenuMetrics.informationHeight))
            host.autoresizingMask = [.width]
            item.view = host
            informationItems.append(item)
            menu.addItem(item)
        }
        let keychain = NSMenuItem(title: "Allow Keychain Access…", action: #selector(allowClaudeAccess), keyEquivalent: "")
        keychain.target = self
        keychain.tag = 1
        keychain.isHidden = true
        menu.addItem(keychain)
        MenuQuitShortcut.install(in: menu, target: NSApplication.shared,
            action: #selector(NSApplication.terminate(_:)))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuMetrics.statusIcon()
        item.button?.imageScaling = MenuMetrics.statusImageScaling
        item.button?.setAccessibilityLabel("Allowance usage")
        item.menu = menu
        statusItem = item
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReadouts() }
        }
        observation = CredentialObservation(changed: { [weak self] in
            Task { await self?.model.auditCredentials() }
        }, refresh: { [weak self] in
            Task { await self?.model.refresh() }
        })
        resetMonitor = ResetMonitor(onConfirmed: { [weak self] in
            self?.model.refreshIfNeeded()
        })
        resetMonitor?.start()
        if let i = CommandLine.arguments.firstIndex(of: "--notification-test"), CommandLine.arguments.indices.contains(i + 1) {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await resetMonitor?.notificationTest(to: CommandLine.arguments[i + 1])
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--reset-evidence"), CommandLine.arguments.indices.contains(i + 1) {
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await resetMonitor?.writeEvidence(to: CommandLine.arguments[i + 1])
            }
        }
        updateReadouts()
        if let i = CommandLine.arguments.firstIndex(of: "--quit-shortcut-test"), CommandLine.arguments.indices.contains(i + 1) {
            shortcutTestPath = CommandLine.arguments[i + 1]
            let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                // This timer is installed only on the main run loop below.
                MainActor.assumeIsolated {
                    guard let self, let event = MenuQuitShortcut.testEvent(
                        windowNumber: self.informationItems.first?.view?.window?.windowNumber ?? 0) else { return }
                    self.shortcutTestDispatched = true
                    self.shortcutTestMenuWasOpen = self.menuIsOpen
                    self.writeShortcutTestEvidence(stage: "dispatching")
                    // Owned event queue, normal native menu tracking; no direct quit call.
                    NSApplication.shared.postEvent(event, atStart: true)
                    self.writeShortcutTestEvidence(stage: "posted")
                }
            }
            shortcutTestTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.statusItem?.button?.performClick(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        observation?.stop(); resetMonitor?.stop(); shortcutTestTimer?.invalidate()
        writeShortcutTestEvidence(stage: "terminated")
    }

    private func writeShortcutTestEvidence(stage: String) {
        guard let path = shortcutTestPath else { return }
        let record: [String: Any] = ["stage": stage, "nativeCommandQDispatched": shortcutTestDispatched,
            "menuWasOpenOnDispatch": shortcutTestMenuWasOpen,
            "applicationWillTerminateObserved": stage == "terminated",
            "visibleMenuTitles": menu.items.filter { !$0.isHidden }.map(\.title),
            "quitItemVisible": menu.items.contains { $0.tag == MenuQuitShortcut.tag && !$0.isHidden }]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateReadouts()
        model.refreshIfNeeded()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        writeMenuEvidence()
    }

    private func updateReadouts() {
        let now = Date()
        for (item, snapshot) in zip(informationItems, model.snapshots) {
            let readout = MenuReadout(snapshot: snapshot, now: now, issue: model.issues[snapshot.provider])
            // Do not put the long accessibility/tooltip summary into the native title:
            // hidden native titles can still contribute to NSMenu's width calculation.
            item.title = readout.title
            item.toolTip = nil
            (item.view as? NSHostingView<UsageInformationView>)?.rootView = UsageInformationView(readout: readout)
            item.view?.setAccessibilityLabel(readout.summary)
        }
        menu.item(withTag: 1)?.isHidden = model.issues["claude-fable"] != LiveReadError.keychainPermission.message
        statusItem?.button?.toolTip = nil
        writeMenuEvidence()
    }

    private func writeMenuEvidence() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--evidence"), arguments.indices.contains(index + 1) else { return }
        var record = model.evidence(at: Date())
        record["pid"] = ProcessInfo.processInfo.processIdentifier
        record["presentation"] = "NSMenu + NSHostingView"
        record["uiLanguage"] = "en"
        record["customDrawing"] = true
        record["progressRenderer"] = "SwiftUI.Capsule.readOnly"
        record["progressHeight"] = NativeUsageBar.height
        record["customPanel"] = false
        record["menuOpen"] = menuIsOpen
        record["menuWidth"] = menu.size.width
        record["informationWidth"] = MenuMetrics.width
        record["statusIconSize"] = statusItem?.button?.image?.size.width ?? 0
        record["statusImageScaling"] = statusItem?.button?.imageScaling == .scaleNone ? "none" : "scaled"
        record["hoverHelpEnabled"] = statusItem?.button?.toolTip != nil || informationItems.contains { $0.toolTip != nil || $0.view?.toolTip != nil }
        record["paceWords"] = model.snapshots.map {
            MenuReadout(snapshot: $0, now: Date(), issue: model.issues[$0.provider]).pace
        }
        record["quotaLabelPlacement"] = "inline"
        record["remainingLabels"] = model.snapshots.map {
            MenuReadout(snapshot: $0, now: Date(), issue: model.issues[$0.provider]).remainingLabel
        }
        record["visibleMenuTitles"] = menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "separator" : $0.title }
        record["providerArtworkTemplate"] = true
        record["progressTint"] = "appearance-resolved monochrome"
        record["progressMeaning"] = "filled = used; empty = remaining"
        record["progressValues"] = model.snapshots.map { $0.remainingFraction.map { 1 - $0 } as Any? ?? NSNull() }
        record["informationRows"] = informationItems.map {
            ["title": $0.title, "enabled": $0.isEnabled, "hasAction": $0.action != nil,
             "width": $0.view?.frame.width ?? 0, "height": $0.view?.frame.height ?? 0] as [String: Any]
        }
        if let quit = menu.item(withTag: MenuQuitShortcut.tag) {
            record["hiddenQuitShortcut"] = ["key": quit.keyEquivalent,
                "commandOnly": quit.keyEquivalentModifierMask == .command,
                "hidden": quit.isHidden, "enabled": quit.isEnabled,
                "allowedWhenHidden": quit.allowsKeyEquivalentWhenHidden] as [String: Any]
        }
        record["actions"] = menu.items.filter { $0.action != nil && !$0.isHidden }.map(\.title)
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arguments[index + 1] + ".menu.json"), options: .atomic)
        }
    }

    // The user explicitly invokes the system permission prompt; background reads never prompt.
    @objc private func allowClaudeAccess() { Task { await model.refresh(allowClaudeInteraction: true) } }
}

@MainActor
struct UsageInformationView: View {
    let readout: MenuReadout
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(nsImage: readout.brand.image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: MenuMetrics.providerIconSize, height: MenuMetrics.providerIconSize)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                    .accessibilityHidden(true)
                Text(readout.title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                if readout.remainingFraction != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(readout.remaining).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        Text(readout.remainingLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.fixedSize()
                }
            }
            if let used = readout.usedFraction {
                NativeUsageBar(used: used, scheme: colorScheme)
                    .opacity(0.75)
                    .accessibilityLabel("Weekly quota used")
                    .accessibilityValue("\(Int((used * 100).rounded()))% used")
                    .frame(height: NativeUsageBar.height)
                HStack(alignment: .firstTextBaseline) {
                    Text(readout.reset)
                    Spacer(minLength: 8)
                    Text(readout.pace)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if let status = readout.unavailableText {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: MenuMetrics.width, height: MenuMetrics.informationHeight, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readout.summary)
    }
}
