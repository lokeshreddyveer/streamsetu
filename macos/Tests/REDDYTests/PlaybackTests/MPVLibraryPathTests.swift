import Testing
import Foundation
@testable import REDDY

/// Where libmpv may come from. A shipped (team-signed) build loads only its own bundled copy; the environment variable and Homebrew belong to an unsigned developer build.
@Suite("MPV library search paths") struct MPVLibraryPathTests {
    private let frameworks = "/Applications/StreamSetu.app/Contents/Frameworks"

    @Test func aSignedBuildLoadsOnlyItsBundledLibrary() {
        let paths = MPVLibrary.searchPaths(signedBuild: true, environment: ["REDDY_LIBMPV": "/tmp/evil/libmpv.dylib"], frameworks: frameworks)
        #expect(paths == ["\(frameworks)/libmpv.2.dylib", "\(frameworks)/libmpv.dylib"])
    }

    @Test func aSignedBuildIgnoresHomebrewAndTheEnvironmentEvenWithNoBundledCopy() {
        let paths = MPVLibrary.searchPaths(signedBuild: true, environment: ["REDDY_LIBMPV": "/tmp/evil/libmpv.dylib"], frameworks: nil)
        #expect(paths.isEmpty, "no library at all is better than one nobody signed: the MPV engine then reports itself unavailable")
        #expect(!paths.contains { $0.contains("homebrew") || $0.contains("/usr/local") || $0.contains("evil") })
    }

    @Test func anUnsignedDeveloperBuildMayUseTheEnvironmentFirstAndThenHomebrew() {
        let paths = MPVLibrary.searchPaths(signedBuild: false, environment: ["REDDY_LIBMPV": "/dev/libmpv.dylib"], frameworks: frameworks)
        #expect(paths.first == "/dev/libmpv.dylib")
        #expect(paths.contains("\(frameworks)/libmpv.2.dylib"))
        #expect(paths.contains("/opt/homebrew/lib/libmpv.dylib"))
    }

    @Test func aDeveloperBuildWithNothingSetStillFindsHomebrew() {
        let paths = MPVLibrary.searchPaths(signedBuild: false, environment: [:], frameworks: nil)
        #expect(paths.first == "/opt/homebrew/lib/libmpv.dylib")
    }
}
