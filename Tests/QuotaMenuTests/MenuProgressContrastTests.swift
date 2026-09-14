import AppKit
import SwiftUI
import XCTest
@testable import QuotaMenu

@MainActor
final class MenuProgressContrastTests: XCTestCase {
    func testUsedAndRemainingRemainDistinctOnLightDarkAndTintedMenuBackdrops() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let cases: [(String, ColorScheme, NSColor)] = [
            ("light", .light, NSColor(white: 0.7, alpha: 1)),
            ("tinted", .light, NSColor(red: 0.78, green: 0.81, blue: 0.64, alpha: 1)),
            ("dark", .dark, NSColor(white: 0.2, alpha: 1))
        ]
        for (name, scheme, background) in cases {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
            container.wantsLayer = true
            container.layer?.backgroundColor = background.cgColor
            let host = NSHostingView(rootView: NativeUsageBar(used: 0.29, scheme: scheme)
                .opacity(0.75).frame(width: 236, height: 4).environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 12, y: 14, width: 236, height: 4)
            container.addSubview(host)
            let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .vibrantDark : .vibrantLight)
            window.contentView = container
            container.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 520, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = container.bounds.size
            container.cacheDisplay(in: container.bounds, to: bitmap)
            func luminance(_ x: Int, _ y: Int) throws -> Double {
                let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            }
            let fill = try luminance(44, 32)
            let remaining = try luminance(450, 32)
            print("Bar visibility \(name): used=\(fill), remaining=\(remaining), difference=\(abs(fill - remaining))")
            // Original test accepted a 0.003 difference: practically invisible.
            // Require a meaningful distinction, not just two unequal pixels.
            XCTAssertGreaterThanOrEqual(abs(fill - remaining), 0.12, name)
            if scheme == .light { XCTAssertLessThan(fill, remaining) }
            else { XCTAssertGreaterThan(fill, remaining) }
            if let dir = ProcessInfo.processInfo.environment["QUOTA_RENDER_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("contrast-\(name).png"))
            }
            window.contentView = nil
        }
    }
}
