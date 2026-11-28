import Foundation
import Testing

/// What runs inside `AppContainer.init` runs on the main thread, before the first window can draw: while it runs the opening cannot start and every screen waits. A launch that asks the database
/// about every remembered title (`RecommendationMemory.purgeRestricted`, a heavy correlated query) did exactly that and held the window for more than five seconds on a large library.
/// That purge belongs in the background task at the end of `wirePrivacy` (after the indexes are built). This guard fails if it is called directly in the start-up body again.
struct LaunchMainThreadGuardTests {
    @Test func theLaunchPurgeIsNotRunOnTheMainThreadInTheContainersStartUp() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Application/AppContainer.swift")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A statement at the function body's own indentation (eight spaces) runs at start-up; one inside a closure or a Task is indented further.
        let direct = lines.enumerated().filter { $0.element == "        _ = try? memory.purgeRestricted()" }.map { $0.offset + 1 }
        #expect(direct.isEmpty, "AppContainer.swift lines \(direct): purgeRestricted() runs on the main thread at launch; run it in the background task instead")
        // And it is still run at launch, in the background, after the indexes.
        let text = lines.joined(separator: "\n")
        let ensure = try #require(text.range(of: "SchemaV19.ensureQueryIndexes(db: database)"))
        let purge = try #require(text.range(of: "_ = try? memory.purgeRestricted()", range: ensure.upperBound..<text.endIndex))
        #expect(text[ensure.upperBound..<purge.lowerBound].count < 400, "the launch purge follows the index build in the same background task")
    }
}
