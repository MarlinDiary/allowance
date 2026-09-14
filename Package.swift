// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "QuotaMenu", targets: ["QuotaMenu"])],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "QuotaMenu", dependencies: ["QuotaCore"], resources: [.copy("Resources")]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaMenuTests", dependencies: ["QuotaMenu", "QuotaCore"])
    ],
    swiftLanguageModes: [.v5]
)
