import AppKit
import QuotaCore
import SwiftUI
import XCTest
@testable import QuotaMenu

@MainActor
final class MenuAppearanceTests: XCTestCase {
    func testProgressHasCompleteThinGeometryAndClampsInvalidValues() {
        XCTAssertEqual(NativeUsageBar.height, 4)
        for (input, expected) in [(0.29, 0.29), (-1.0, 0.0), (2.0, 1.0), (Double.nan, 0.0), (Double.infinity, 0.0)] {
            XCTAssertEqual(NativeUsageBar(used: input, scheme: .light).fraction, expected)
        }
    }

    func testOfficialArtworkLoadsWithoutNetwork() {
        for brand in ProviderBrand.allCases {
            XCTAssertTrue(brand.resourceURL.isFileURL)
            XCTAssertTrue(brand.image.isValid)
            XCTAssertTrue(brand.image.isTemplate)
            XCTAssertGreaterThan(brand.image.size.width, 0)
        }
        XCTAssertEqual(ProviderBrand.openAI.resourceURL.lastPathComponent, "OpenAI.svg")
        XCTAssertEqual(ProviderBrand.claude.resourceURL.lastPathComponent, "Claude.svg")
    }

    func testMenuBarIconMatchesCompactReferenceSize() {
        let icon = MenuMetrics.statusIcon()
        XCTAssertTrue(icon.isTemplate)
        // SF Symbols' natural canvas is 17pt on macOS 15, 18pt on macOS 27.
        // The actual native button glyph is 30px at 2x on both (separate test).
        XCTAssertEqual(icon.size.width, icon.size.height)
        XCTAssertGreaterThanOrEqual(icon.size.width, 17)
        XCTAssertLessThanOrEqual(icon.size.width, 18)
        XCTAssertEqual(MenuMetrics.statusImageScaling, .scaleNone)
    }

    func testSymbolSizeThroughNativeButtonRatherThanForcedImageDrawing() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let old = try XCTUnwrap(NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .small)))
        old.size = NSSize(width: 13, height: 13)
        old.isTemplate = true
        let enlargedCanvasOnly = try XCTUnwrap(old.copy() as? NSImage)
        enlargedCanvasOnly.size = NSSize(width: 19, height: 19)
        for (image, expected) in [(old, 20), (enlargedCanvasOnly, 20), (MenuMetrics.statusIcon(), 30)] {
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
            button.title = ""
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.imageScaling = MenuMetrics.statusImageScaling
            button.contentTintColor = .black
            button.image = image
            let host = NSView(frame: button.frame)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.white.cgColor
            host.addSubview(button)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 56, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            var xs = [Int](), ys = [Int]()
            for y in 0..<48 { for x in 0..<56 {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.alphaComponent > 0.5 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3 {
                    xs.append(x); ys.append(y)
                }
            }}
            let width = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min()) + 1
            let height = try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()) + 1
            XCTAssertEqual(width, expected)
            XCTAssertEqual(height, expected)
            print("Native NSButton glyph: \(width)x\(height)px at 2x; expected \(expected)px")
            window.contentView = nil
        }
    }

    func testEmptyTrackIsRemainingAndFillIsUsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = DemoScenario.everyday.snapshots(at: now).map { MenuReadout(snapshot: $0, now: now) }
        XCTAssertEqual(rows[0].remainingFraction!, 0.68, accuracy: 0.0001)
        XCTAssertEqual(rows[1].remainingFraction!, 0.36, accuracy: 0.0001)
        XCTAssertEqual(rows[0].usedFraction!, 0.32, accuracy: 0.0001)
        XCTAssertEqual(rows[1].usedFraction!, 0.64, accuracy: 0.0001)
        XCTAssertEqual(MenuMetrics.width, 260)
        XCTAssertEqual(MenuMetrics.informationHeight, 66)
    }

    func testUnknownOmitsBarAndZeroRemainingFillsUsedTrack() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for snapshot in DemoScenario.disconnected.snapshots(at: now) {
            XCTAssertNil(MenuReadout(snapshot: snapshot, now: now).remainingFraction)
            XCTAssertNil(MenuReadout(snapshot: snapshot, now: now).usedFraction)
        }
        for snapshot in DemoScenario.exhausted.snapshots(at: now) {
            XCTAssertEqual(MenuReadout(snapshot: snapshot, now: now).remainingFraction, 0)
            XCTAssertEqual(MenuReadout(snapshot: snapshot, now: now).usedFraction, 1)
        }
    }

    func testNativeInformationLayoutRenders() throws {
        // Component rendering only: never captures or operates any user UI.
        // The same SwiftUI view used inside NSMenu is rendered into an offscreen bitmap.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scenarios: [(String, NSAppearance.Name, ColorScheme, DemoScenario)] = [
            ("light", NSAppearance.Name.aqua, ColorScheme.light, DemoScenario.everyday),
            ("dark", .darkAqua, .dark, .everyday),
            ("low", .aqua, .light, .fast),
            ("unknown", .aqua, .light, .disconnected)
        ]
        var cases = scenarios.map { name, appearance, scheme, scenario in
            (name, appearance, scheme, scenario.snapshots(at: now), [String: String](), now)
        }
        cases += [("stale", .darkAqua, .dark, DemoScenario.everyday.snapshots(at: now),
                   ["codex": "Offline", "claude-fable": "Rate limited"], now)]
        if let path = ProcessInfo.processInfo.environment["QUOTA_LIVE_EVIDENCE_PATH"] {
            let evidence = try Data(contentsOf: URL(fileURLWithPath: path))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: evidence) as? [String: Any])
            let rows = try XCTUnwrap(object["snapshots"] as? [[String: Any]])
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let liveNow = try XCTUnwrap(attributes[.modificationDate] as? Date)
            var issues = [String: String]()
            let values = try rows.map { row -> UsageSnapshot in
                let provider = try XCTUnwrap(row["provider"] as? String)
                if let issue = row["issue"] as? String { issues[provider] = issue }
                let end = (row["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                return UsageSnapshot(provider: provider, title: provider == "codex" ? "Codex" : "Fable",
                    accountID: nil, accountLabel: "Current account", usedPercent: row["usedPercent"] as? Double,
                    windowStart: end?.addingTimeInterval(-604800), resetsAt: end,
                    observedAt: liveNow.addingTimeInterval(-(row["ageSeconds"] as? Double ?? 0)))
            }
            XCTAssertEqual(values.count, 2)
            cases += [("live-light", .aqua, .light, values, issues, liveNow), ("live-dark", .darkAqua, .dark, values, issues, liveNow)]
        }
        for (name, appearance, scheme, snapshots, issues, renderNow) in cases {
            let content = VStack(spacing: 0) {
                UsageInformationView(readout: MenuReadout(snapshot: snapshots[0], now: renderNow, issue: issues[snapshots[0].provider]))
                    .frame(height: MenuMetrics.informationHeight)
                Divider()
                UsageInformationView(readout: MenuReadout(snapshot: snapshots[1], now: renderNow, issue: issues[snapshots[1].provider]))
                    .frame(height: MenuMetrics.informationHeight)
            }
            .frame(width: MenuMetrics.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: MenuMetrics.width,
                                height: MenuMetrics.informationHeight * 2 + 1)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000)
            if let directory = ProcessInfo.processInfo.environment["QUOTA_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try png.write(to: url.appendingPathComponent("preview-\(name).png"))
            }
            window.contentView = nil
        }
    }
}
