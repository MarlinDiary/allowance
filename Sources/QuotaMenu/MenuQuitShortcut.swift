import AppKit

/// A local native menu command, not a global shortcut or event monitor.
@MainActor
enum MenuQuitShortcut {
    static let tag = 2

    @discardableResult
    static func install(in menu: NSMenu, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "Quit Allowance", action: action, keyEquivalent: "q")
        item.target = target
        item.tag = tag
        item.keyEquivalentModifierMask = .command
        item.isEnabled = true
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        menu.addItem(item)
        return item
    }

    // Owned component/smoke-test input only. This does not post keyboard events.
    static func testEvent(key: String = "q", modifiers: NSEvent.ModifierFlags = .command, windowNumber: Int = 0) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "q" ? 12 : 14)
    }
}
