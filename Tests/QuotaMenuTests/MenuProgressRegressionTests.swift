import AppKit
import QuotaCore
import SwiftUI
import XCTest
@testable import QuotaMenu
@MainActor
final class MenuProgressRegressionTests: XCTestCase {
    func testProgressColorsMatchAcrossIndependentMenuRows() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshots = DemoScenario.everyday.snapshots(at: now)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.vibrantLight),
                                           ("dark", .dark, .vibrantDark)] {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 136))
            container.wantsLayer = true
            container.layer?.backgroundColor = (scheme == .light ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.2, alpha: 1)).cgColor
            let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = container
            for (index, snapshot) in snapshots.enumerated() {
                // Separate hosts, initial opposite appearance, then independent root
                // updates: mirrors menu rows first constructed before data arrives.
                let empty = DemoScenario.disconnected.snapshots(at: now)[index]
                let host = NSHostingView(rootView: UsageInformationView(readout: MenuReadout(snapshot: empty, now: now)).environment(\.colorScheme, scheme == .light ? .dark : .light))
                host.frame = NSRect(x: 0, y: index == 0 ? 70 : 0, width: 260, height: 66)
                container.addSubview(host)
                host.rootView = UsageInformationView(readout: MenuReadout(snapshot: snapshot, now: now)).environment(\.colorScheme, scheme)
            }
            container.layoutSubtreeIfNeeded()
            print("Row host frames", container.subviews.map { $0.frame })
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 520, pixelsHigh: 272,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = container.bounds.size
            container.cacheDisplay(in: container.bounds, to: rep)
            func brightness(_ x: Int, _ y: Int) throws -> Double {
                let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                return (c.redComponent + c.greenComponent + c.blueComponent) / 3
            }
            // Bar lies directly under the 18pt header; sample the middle of its fill.
            let first = try brightness(40, 69)
            let second = try brightness(40, 209)
            print("Independent menu rows \(name): Codex fill=\(first), Claude fill=\(second)")
            XCTAssertEqual(first, second, accuracy: 0.04)
            let background = scheme == .light ? 0.7 : 0.2
            let filledYs = try (58..<82).filter { abs(try brightness(40, $0) - background) > 0.10 }
            XCTAssertEqual(filledYs.count, 8) // complete 4pt capsule at 2x, on every OS
            let track = try brightness(440, 69)
            XCTAssertGreaterThanOrEqual(abs(first - track), 0.12)
            if scheme == .light {
                XCTAssertGreaterThan(first, 0.40) // not the heavy rejected 0.36
                XCTAssertLessThan(first, track)
            } else { XCTAssertGreaterThan(first, track) }
            if let path = ProcessInfo.processInfo.environment["QUOTA_RENDER_DIR"] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("independent-\(name).png"))
            }
            window.contentView = nil
        }
    }

}
