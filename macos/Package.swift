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

// The optional built-in keys (TMDB, fanart.tv, TheTVDB) are generated, gitignored files (Scripts/gen-builtin-key.py); the code that reads each is compiled only when its file exists.
let generatedDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/REDDY/Generated").path
let builtInFlag: [SwiftSetting] = [("GeneratedTMDB", "STREAMSETU_BUILTIN_TMDB"), ("GeneratedFanart", "STREAMSETU_BUILTIN_FANART"), ("GeneratedTVDB", "STREAMSETU_BUILTIN_TVDB")]
    .filter { FileManager.default.fileExists(atPath: generatedDir + "/" + $0.0 + ".swift") }.map { .define($0.1) }

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
            swiftSettings: [.swiftLanguageMode(.v6)] + builtInFlag
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
