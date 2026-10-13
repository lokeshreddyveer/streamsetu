// swift-tools-version:6.0
import PackageDescription
import Foundation

// With only the Command Line Tools installed (no Xcode), Swift Testing lives outside the default search path.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTesting = FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
let testSwiftFlags: [SwiftSetting] = cltTesting ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testLinkFlags: [LinkerSetting] = cltTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                     "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"])]
    : []

let package = Package(
    name: "REDDY",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "REDDY",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/REDDY",
            exclude: ["Resources/README.txt"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "REDDYTests",
            dependencies: ["REDDY"],
            path: "Tests/REDDYTests",
            swiftSettings: testSwiftFlags,
            linkerSettings: testLinkFlags
        ),
    ]
)
