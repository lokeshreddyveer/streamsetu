// swift-tools-version:6.0
import PackageDescription

// Own package so the app build never pays for swift-syntax. Run through Scripts/check-atlas.sh.
let package = Package(
    name: "AtlasScan",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "600.0.1"),
    ],
    targets: [
        .target(name: "AtlasScanCore", dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .executableTarget(name: "atlas-scan", dependencies: ["AtlasScanCore"]),
        .testTarget(name: "AtlasScanTests", dependencies: ["AtlasScanCore"]),
    ]
)
