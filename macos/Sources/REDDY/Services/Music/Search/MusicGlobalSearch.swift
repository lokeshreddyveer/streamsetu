import Foundation

// Music results in the app-wide search (the top search box, Cmd+K). They appear only when the person finished Music's first-run consent and a metadata source
// is switched on; with either missing the search never touches Music, so nothing is sent anywhere by a search for a film.

/// Where choosing a Music result goes.
enum MusicSearchTarget: Hashable, Sendable {
    case track(MusicTrack), album(MusicAlbum), artist(MusicArtist)
}

enum MusicGlobalSearch {
    /// How many Music rows one search shows.
    static let limit = 6
    static let minimumCharacters = 2

    typealias Provider = @Sendable (String, Int) async -> [SearchResult]

    private final class Hook: @unchecked Sendable {
        private let lock = NSLock()
        private var fn: Provider?
        func set(_ f: Provider?) { lock.lock(); fn = f; lock.unlock() }
        func get() -> Provider? { lock.lock(); defer { lock.unlock() }; return fn }
    }
    private static let hook = Hook()

    /// Connects the search to Music. Call once when Music is attached (and again is harmless). `uninstall()` disconnects it, for example when Music is switched off.
    @MainActor static func install(registry: MusicRegistry, library: MusicLibrary) {
        hook.set { query, limit in await results(registry: registry, library: library, query: query, limit: limit) }
    }
    static func uninstall() { hook.set(nil) }
    /// Connects a stand-in provider so the wiring can be tested without a registry.
    static func installForTesting(_ f: @escaping Provider) { hook.set(f) }
    static var isInstalled: Bool { hook.get() != nil }

    /// Rows for the app-wide search, empty when Music is not connected.
    static func rows(for query: String, limit: Int = limit) async -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= minimumCharacters, let f = hook.get() else { return [] }
        return await f(q, limit)
    }

    @MainActor
    static func results(registry: MusicRegistry, library: MusicLibrary, query: String, limit: Int) async -> [SearchResult] {
        guard library.settings.consentDone, let provider = registry.activeMetadata else { return [] }
        // A source that only describes songs (a catalogue) is never searched here: its rows could not be played.
        if MusicCatalogRuntime.shared.isEnabled, MusicSearchEnrichment.isCatalogueOnly(provider.capabilities) { return [] }
        let found = (try? await provider.search(query, types: [.track, .album, .artist])) ?? []
        let name = provider.info.name
        var out: [SearchResult] = []
        for (i, r) in found.enumerated() {
            switch r {
            case .track(let t):
                out.append(row(id: "music:track:" + t.uid, title: t.title, subtitle: [t.artistLine, t.album?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), source: name,
                               art: t.thumbnails.best(minSide: 120), target: .track(t), query: query, position: i))
            case .album(let a):
                out.append(row(id: "music:album:" + a.uid, title: a.title, subtitle: "Album · " + a.artists.map(\.name).joined(separator: ", "), source: name,
                               art: a.thumbnails.best(minSide: 120), target: .album(a), query: query, position: i))
            case .artist(let a):
                out.append(row(id: "music:artist:" + a.uid, title: a.name, subtitle: "Artist", source: name, art: a.thumbnails.best(minSide: 120), target: .artist(a), query: query, position: i))
            default: break
            }
        }
        var seen = Set<String>()
        let ranked = out.filter { seen.insert($0.id).inserted }.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }.map(\.element)
        return Array(ranked.prefix(limit))
    }

    private static func row(id: String, title: String, subtitle: String, source: String, art: String?, target: MusicSearchTarget, query: String, position: Int) -> SearchResult {
        SearchResult(id: id, kind: .music, title: title, subtitle: subtitle, sourceID: nil, sourceName: source, artworkURL: art, destination: .music(target),
                     score: GlobalSearchService.score(title: title, query: query, position: position))
    }
}
