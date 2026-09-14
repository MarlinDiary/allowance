import AppKit
import SwiftUI

/// Standard progress indicator, at Apple's recommended native control size.
/// Resolve appearance on the indicator alone, never the menu/window. No custom
/// drawing, forced intrinsic height, fill colors or unsupported tint API.
@MainActor
struct NativeUsageBar: NSViewRepresentable {
    let used: Double
    let scheme: ColorScheme

    static func makeIndicator(for scheme: ColorScheme) -> NSProgressIndicator {
        let view = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 236, height: 12))
        view.style = .bar
        view.controlSize = .small
        view.isIndeterminate = false
        view.isDisplayedWhenStopped = true
        view.minValue = 0; view.maxValue = 1
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.sizeToFit() // retain the complete native capsule; don't squash the cell
        return view
    }

    func makeNSView(context: Context) -> NSProgressIndicator { Self.makeIndicator(for: scheme) }

    func updateNSView(_ view: NSProgressIndicator, context: Context) {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.doubleValue = min(1, max(0, used))
        view.setAccessibilityLabel("Weekly quota used")
        view.setAccessibilityValue("\(Int((view.doubleValue * 100).rounded()))% used")
    }
}
