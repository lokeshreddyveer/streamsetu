import Foundation
@testable import REDDY

/// The Awaara (1951) fixture graph for the connected-page scenarios: the app's entity runtime is pointed at an in-memory copy of it, once per process.
@MainActor
enum MusicSnapshotGraph {
    private static var built: SoundtrackFixtureGraph?

    static func seed() async throws {
        if built == nil { built = try await SoundtrackFixtureGraph.build() }
        guard let g = built else { return }
        MusicEntityRuntime.shared.use(graph: g.graph)
        MusicCreditsTab.entityOverride = g.recordings["Awaara Hoon"]
    }

    /// The route a scenario starts on.
    static func route(for c: MusicSnapshotCase) -> MusicRoute? {
        guard let g = built else { return nil }
        switch c {
        case .soundtrackPage: return .entity(g.album)
        case .songPage: return g.recordings["Awaara Hoon"].map { .entity($0) }
        case .personRajKapoor: return g.people["Raj Kapoor"].map { .entity($0, role: .actor) }
        case .personMukesh: return g.people["Mukesh"].map { .entity($0, role: .singer) }
        case .personShankarJaikishan: return g.people["Shankar-Jaikishan"].map { .entity($0, role: .musicDirector) }
        case .filmPage: return .entity(g.film)
        case .personDirector: return g.people["Raj Kapoor"].map { .entity($0, role: .director) }
        default: return nil
        }
    }
}
