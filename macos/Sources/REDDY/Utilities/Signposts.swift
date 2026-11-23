import Foundation
import os

/// Signposts for the smoothness work: open Instruments (Hitches, os_signpost) and filter on subsystem "app.streamsetu" and category "Smooth".
/// They cost next to nothing when no tool is attached, and carry no titles, addresses or logins: names only.
enum SmoothSignpost {
    nonisolated static let signposter = OSSignposter(subsystem: "app.streamsetu", category: "Smooth")

    /// Names of the intervals, so the scripts and the tests can look for them.
    static let names = ["HomeLoad", "FolderRowsEnsureTiles", "SearchRun", "TileImageLoad", "TitleOpen"]

    nonisolated static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }
    nonisolated static func end(_ state: OSSignpostIntervalState, _ name: StaticString) {
        signposter.endInterval(name, state)
    }

    /// Runs `body` inside a named interval.
    nonisolated static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let s = begin(name); defer { signposter.endInterval(name, s) }
        return try body()
    }
    static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let s = begin(name); defer { signposter.endInterval(name, s) }
        return try await body()
    }
}
