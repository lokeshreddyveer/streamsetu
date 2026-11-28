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
let builtInFlag: [SwiftSetting] = [("GeneratedTMDB", "STREAMSETU_BUILTIN_TMDB"), ("GeneratedFanart", "STREAMSETU_BUILTIN_FANART"), ("GeneratedTVDB", "STREAMSETU_BUILTIN_TVDB"), ("GeneratedLastFM", "STREAMSETU_BUILTIN_LASTFM"), ("GeneratedLastFMSecret", "STREAMSETU_BUILTIN_LASTFM_SECRET"), ("GeneratedAcoustID", "STREAMSETU_BUILTIN_ACOUSTID"), ("GeneratedSetlistFM", "STREAMSETU_BUILTIN_SETLISTFM")]
    .filter { FileManager.default.fileExists(atPath: generatedDir + "/" + $0.0 + ".swift") }.map { .define($0.1) }

let package = Package(
    name: "REDDY",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Chromaprint 1.6.2 (acoustid.org/chromaprint), vendored unmodified, with Apple's vDSP for the FFT. Its resampler is FFmpeg-derived (LGPL 2.1), so it stays a
        // separate target with its own LICENSE.md. It only turns audio into a fingerprint; nothing in it touches the network.
        .target(
            name: "CChromaprint",
            path: "Sources/CChromaprint",
            exclude: ["LICENSE.md"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("."), .define("HAVE_CONFIG_H"), .define("CHROMAPRINT_NODLL")],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "REDDY",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "CChromaprint"],
            path: "Sources/REDDY",
            exclude: ["Resources/README.txt", "Services/Music/Plugins/SAMPLE-PLUGIN.md"],
            swiftSettings: [.swiftLanguageMode(.v6)] + builtInFlag
        ),
        .testTarget(
            name: "REDDYTests",
            dependencies: ["REDDY"],
            path: "Tests/REDDYTests",
            swiftSettings: testSwiftFlags,
            linkerSettings: testLinkFlags
        ),
    ],
    cxxLanguageStandard: .cxx17
)
