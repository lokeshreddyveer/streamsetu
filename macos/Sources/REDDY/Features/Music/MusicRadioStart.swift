import SwiftUI

// Starting a station: a seed that is not yet a song (a genre, a language, a country's charts) is first turned into a real song from the person's
// own sources, then the existing radio start plays it. A station that finds nothing says so and is not added to the recent list.

/// Which station the person started from this page, so the "Now on radio" card can name it. The player itself says whether a radio is running.
@MainActor @Observable
final class MusicRadioNow {
    static let shared = MusicRadioNow()
    private(set) var station: MusicStation?
    func started(_ s: MusicStation) { station = s }
    func clear() { station = nil }
}

enum MusicRadioSeedPicking {
    /// The first song, preferring one written in the asked language when a language is given.
    static func pick(_ tracks: [MusicTrack], languageKey: String?, blocked: (MusicTrack) -> Bool = { _ in false }) -> MusicTrack? {
        let usable = tracks.filter { !blocked($0) && $0.isPodcast != true }
        if let languageKey, let hit = usable.first(where: { MusicLanguageDetect.language(of: ([$0.title] + $0.artists.map(\.name)).joined(separator: " ")) == languageKey }) { return hit }
        return usable.first
    }
}

@MainActor
enum MusicRadioStart {
    /// Starts the station. Returns true when a radio began.
    @discardableResult
    static func start(_ station: MusicStation, hub: MusicHub) async -> Bool {
        let started: Bool
        switch station.seed {
        case .track(let t):
            await MusicQueueActions.startRadio(t, hub: hub); started = true
        case .artist(let a):
            await MusicEntityActions.startRadio(.artist(a), hub: hub); started = true
        case .search(let q, let lang):
            guard let t = await searchSeed(q, languageKey: lang, hub: hub) else { return noSong() }
            await MusicQueueActions.startRadio(t, hub: hub); started = true
        case .chart(let region, let lang):
            guard let t = await chartSeed(region: region, languageKey: lang, hub: hub) else { return noSong() }
            await MusicQueueActions.startRadio(t, hub: hub); started = true
        }
        if started { MusicRadioNow.shared.started(station) }
        return started
    }

    private static func noSong() -> Bool {
        MusicToasts.shared.show(Localized.string("Nothing to play here yet."))
        return false
    }

    private static func searchSeed(_ query: String, languageKey: String?, hub: MusicHub) async -> MusicTrack? {
        guard let p = hub.registry.activeMetadata, let page = try? await p.searchTracks(query, page: nil) else { return nil }
        return MusicRadioSeedPicking.pick(page.items, languageKey: languageKey, blocked: { hub.library.isBlacklisted($0) })
    }

    /// A new country's first request is the slow one, so a miss gets a second, longer try (as Listen Now and Explore give), not an immediate "nothing here".
    private static func twice<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
        for limit in [MusicHomeLoaders.sourceDeadline, MusicHomeLoaders.secondChance] {
            if Task.isCancelled { return nil }
            if let v = try? await MusicStreamResolver.withDeadline(limit, work) { return v }
        }
        return nil
    }

    /// The top song of a country's chart (or a language's chart), found again on the browsing source so it can start a radio.
    private static func chartSeed(region: String, languageKey: String?, hub: MusicHub) async -> MusicTrack? {
        let language = languageKey.flatMap(MusicLanguage.init(rawValue:))
        for p in hub.registry.discovery where MusicRegionalSources.followsRegion(providerID: p.id, region: region) {
            var sections: [MusicBrowseSection] = []
            if let language, let j = p as? any MusicLanguageDiscovery { sections = await twice { try await j.featured(region: region, languages: [language]) } ?? [] }
            else if language == nil, let r = p as? any MusicRegionalDiscovery { sections = await twice { try await r.featured(region: region) } ?? [] }
            // Only the country's own lists seed "Top <country> Radio"; a worldwide chart a source substituted never does.
            let own = sections.filter { $0.scope.countsAsRegional(for: region, sourceFollowsRegion: true) || (language != nil && $0.scope != .global) }
            let chart = own.flatMap(\.items).compactMap { item -> MusicTrack? in if case .track(let t) = item { return t } else { return nil } }
            guard let top = MusicRadioSeedPicking.pick(MusicRegionalSources.filter(chart, to: language), languageKey: nil, blocked: { hub.library.isBlacklisted($0) }) else { continue }
            // The chart song itself when its source can recommend; otherwise the same song found on the browsing source.
            if hub.registry.metadataProvider(id: top.providerID) != nil, !MusicRegistry.isDiscovery(top.providerID) { return top }
            let words = top.title + " " + (top.artists.first(where: { MusicCompilationArtist.isUsableArtist($0) })?.name ?? "")
            if let found = await searchSeed(words, languageKey: nil, hub: hub) { return found }
        }
        return nil
    }
}
