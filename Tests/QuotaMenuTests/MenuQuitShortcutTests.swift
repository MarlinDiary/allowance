import AppKit
import XCTest
@testable import QuotaMenu

@MainActor
final class MenuQuitShortcutTests: XCTestCase {
    final class Target: NSObject {
        var calls = 0
        @objc func quit(_ sender: Any?) { calls += 1 }
    }

    func testSameCommandQEventBeforeAndAfterHiddenShortcutInstallation() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let menu = NSMenu(); menu.autoenablesItems = false
        let info = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        let target = Target()
        let event = try XCTUnwrap(MenuQuitShortcut.testEvent())
        XCTAssertFalse(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.calls, 0)
        let item = MenuQuitShortcut.install(in: menu, target: target, action: #selector(Target.quit(_:)))
        XCTAssertTrue(item.isHidden)
        XCTAssertTrue(item.allowsKeyEquivalentWhenHidden)
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items.filter { !$0.isHidden }.map(\.title), ["Codex"])
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.calls, 1)
        print("Same native Cmd+Q event: baseline handled=false/calls=0; hidden command handled=true/calls=1; visible titles=[Codex]")
    }

    func testPlainQAndOtherCommandKeysDoNotQuit() throws {
        let menu = NSMenu(); menu.autoenablesItems = false
        let target = Target()
        MenuQuitShortcut.install(in: menu, target: target, action: #selector(Target.quit(_:)))
        for event in [MenuQuitShortcut.testEvent(modifiers: []), MenuQuitShortcut.testEvent(key: "e") ] {
            XCTAssertFalse(menu.performKeyEquivalent(with: try XCTUnwrap(event)))
        }
        XCTAssertEqual(target.calls, 0)
    }

    func testQuitShortcutTargetsNativeApplicationTermination() {
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = MenuQuitShortcut.install(in: menu, target: NSApplication.shared,
            action: #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(item.target === NSApplication.shared)
        XCTAssertEqual(item.action, #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(item.isHidden)
        XCTAssertTrue(item.allowsKeyEquivalentWhenHidden)
    }
}
