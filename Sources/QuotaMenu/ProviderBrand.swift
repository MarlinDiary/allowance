import AppKit

enum ProviderBrand: String, CaseIterable {
    case openAI = "OpenAI"
    case claude = "Claude"

    var fileExtension: String { "svg" }

    var resourceURL: URL {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: fileExtension,
                                          subdirectory: "Resources") else {
            preconditionFailure("Missing bundled provider artwork: \(rawValue)")
        }
        return url
    }

    // Decode once. Display uses original artwork, not a substitute symbol or network image.
    @MainActor private static let images: [ProviderBrand: NSImage] = Dictionary(
        uniqueKeysWithValues: allCases.map { brand in
            guard let image = NSImage(contentsOf: brand.resourceURL) else {
                preconditionFailure("Invalid provider artwork: \(brand.rawValue)")
            }
            image.isTemplate = true
            return (brand, image)
        })

    @MainActor var image: NSImage { Self.images[self]! }
}

enum MenuMetrics {
    static let width: CGFloat = 260
    static let informationHeight: CGFloat = 66
    static let statusIconSize: CGFloat = 18
    static let providerIconSize: CGFloat = 18
    static let statusImageScaling: NSImageScaling = .scaleNone

    static func statusIcon() -> NSImage {
        // Configure the symbol itself. NSButton draws symbol images using these metrics;
        // changing NSImage.size alone does not reliably change the on-screen glyph.
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                            accessibilityDescription: "Allowance usage")!.withSymbolConfiguration(configuration)!
        image.isTemplate = true
        return image
    }
}
