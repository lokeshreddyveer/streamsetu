import Foundation

/// What Listen Now asks the music sources for, each part on its own with a short time limit, so one slow source never holds the page back. Only artist
/// ids, artist names and genre names go out as searches: never the plays, the likes or an account. Answers are kept in memory for a while, so opening Home again asks nothing.
/// Everything here is skipped when Music is gated or the device is offline.
@MainActor
enum MusicHomeSignalLoader {
    private static var releasesCache: (key: String, at: Date, albums: [MusicAlbum])?
    /// Related artists and their songs, kept per seed artist, so a page that picks other seed artists each visit does not fetch the same ones again.
    private static var adjacentByArtist: [String: (at: Date, items: [HomeItem])] = [:]
    static let releasesLifetime: TimeInterval = 12 * 3600
    static let adjacentLifetime: TimeInterval = 6 * 3600
    static let searchLifetime: TimeInterval = 20 * 60
    static let providerDeadline: TimeInterval = 4
    static let searchDeadline: TimeInterval = 8

    static func forget() { releasesCache = nil; adjacentByArtist = [:]; genreShelvesCache = nil; playlistsCache = nil }

    private static func provider(_ id: String, hub: MusicHub) -> (any MusicMetadataProvider)? { hub.registry.metadataProvider(id: id) }

    /// A remembered answer is used only for sources that are still on: one switched off since must feed nothing, however fresh the cache is.
    nonisolated static func fromSourcesOn(_ albums: [MusicAlbum], isOn: (String) -> Bool) -> [MusicAlbum] { albums.filter { isOn($0.providerID) } }

    /// The artists worth asking about: the ones followed first, then the strongest by play weight; each with a usable id and provider.
    static func seedArtists(taste: HomeTaste, followed: [MusicArtist], limit: Int) -> [MusicArtist] {
        var out: [MusicArtist] = []
        var seen = Set<String>()
        for f in followed where !f.id.isEmpty && seen.insert(HomeKeys.fold(f.name)).inserted { out.append(f) }
        for a in taste.artists where !a.ref.id.isEmpty && seen.insert(a.key).inserted {
            out.append(MusicArtist(id: a.ref.id, providerID: a.providerID, name: a.name, thumbnails: a.ref.thumbnails))
        }
        return Array(out.prefix(limit))
    }

    // MARK: new releases

    /// The newest album of each seed artist (any age; the engine decides what is new).
    static func releases(hub: MusicHub, seeds: [MusicArtist]) async -> [MusicAlbum] {
        guard !seeds.isEmpty else { return [] }
        let key = seeds.map(\.uid).joined(separator: ",")
        if let c = releasesCache, c.key == key, Date().timeIntervalSince(c.at) < releasesLifetime {
            MusicDebugLog.log("home", "releases cache hit: \(c.albums.count)")
            return fromSourcesOn(c.albums) { provider($0, hub: hub) != nil }
        }
        let pairs = seeds.compactMap { a in provider(a.providerID, hub: hub).map { (a, $0) } }
        var found: [MusicAlbum] = []
        let deadline = providerDeadline
        await withTaskGroup(of: MusicAlbum?.self) { group in
            var running = 0
            for (artist, p) in pairs {
                if running >= 4, let r = await group.next() { if let r { found.append(r) }; running -= 1 }
                group.addTask {
                    let page = try? await MusicStreamResolver.withDeadline(deadline) { try await p.artistAlbums(id: artist.id, page: nil) }
                    return (page?.items ?? []).filter { !$0.title.isEmpty && !$0.thumbnails.isEmpty }.max { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
                }
                running += 1
            }
            for await r in group { if let r { found.append(r) } }
        }
        // Only a mostly complete answer is remembered for hours: one artist answering out of eight would otherwise hide the rest all day.
        if !found.isEmpty, !Task.isCancelled, found.count * 2 >= pairs.count { releasesCache = (key, Date(), found) }
        let foundCount = found.count, pairCount = pairs.count
        MusicDebugLog.log("home", "releases loaded: \(foundCount) from \(pairCount) artists")
        return found
    }

    // MARK: next to what they play

    /// Related artists of two of the person's artists, and a few songs of some of them: unfamiliar to the person, tied to the artist they sit next to. The two are drawn anew
    /// for each visit (an artist the person plays more is likelier), so the shelf is not the same two artists every time.
    static func adjacent(hub: MusicHub, taste: HomeTaste, seeds: [MusicArtist], visit: UInt64) async -> [HomeItem] {
        guard !seeds.isEmpty else { return [] }
        var rng = HomeRandom.child(of: visit, "adjacent-lead")
        let lead = HomeRandom.sample(Array(seeds.prefix(16)), count: 2, weight: { 1 + taste.artistWeight(named: $0.name) }, using: &rng)
        var out: [HomeItem] = []
        for seed in lead {
            // The source is asked about before the cache: a seed whose source is switched off gives nothing, remembered or not.
            guard let p = provider(seed.providerID, hub: hub) else { continue }
            if let c = adjacentByArtist[seed.uid], Date().timeIntervalSince(c.at) < adjacentLifetime { out += c.items; continue }
            var mine: [HomeItem] = []
            let related = (try? await MusicStreamResolver.withDeadline(providerDeadline) { try await p.relatedArtists(id: seed.id) }) ?? []
            let fresh = related.filter { !$0.name.isEmpty && !taste.isFamiliar(artistKey: HomeKeys.fold($0.name)) && !MusicCompilationArtist.isCompilation($0.name) }.prefix(10)
            for a in fresh { mine.append(HomeItem.make(a).adjacent(to: seed.name)) }
            for a in fresh.prefix(4) {
                let tracks = (try? await MusicStreamResolver.withDeadline(providerDeadline) { try await p.artistTopTracks(id: a.id) }) ?? []
                for t in tracks.prefix(3) where !t.title.isEmpty && !hub.library.isBlacklisted(t) { mine.append(HomeItem.make(t).adjacent(to: seed.name)) }
            }
            if !mine.isEmpty, !Task.isCancelled { adjacentByArtist[seed.uid] = (Date(), mine) }   // a cancelled run holds half an answer
            out += mine
        }
        let outCount = out.count, leadNames = lead.map(\.name).joined(separator: ", ")
        MusicDebugLog.log("home", "adjacent loaded: \(outCount) items next to \(leadNames)")
        return out
    }

    // MARK: the person's languages and folders

    private static var genreShelvesCache: (key: String, at: Date, sections: [HomeSection])?

    /// A shelf for each of the two genres the person listens to most: songs the active source returns for that genre that the person has not played (so it is new to them).
    static func genreShelves(hub: MusicHub, taste: HomeTaste, wording: MusicFillWording) async -> [HomeSection] {
        var weight: [String: Double] = [:], shown: [String: String] = [:]
        for s in taste.tracks where s.plays > 0 || s.liked {
            for g in MusicInsightsEngine.genreLabels(s.track) { let k = MusicText.normalize(g); weight[k, default: 0] += s.weight; shown[k] = g }
        }
        let top = weight.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).compactMap { shown[$0.key] }
        guard !top.isEmpty, let source = hub.registry.activeMetadata else { return [] }
        let played = Set(taste.tracks.map(\.key))
        let key = source.id + "|" + top.joined(separator: ",") + "|\(played.count)|" + Localized.activeCode   // titles are worded in the app's language
        if let c = genreShelvesCache, c.key == key, Date().timeIntervalSince(c.at) < searchLifetime { return c.sections }
        var out: [HomeSection] = []
        for g in top {
            let page = try? await MusicStreamResolver.withDeadline(searchDeadline) { try await source.searchTracks(g + " songs", page: nil) }
            let items = (page?.items ?? []).filter { !$0.thumbnails.isEmpty && !hub.library.isBlacklisted($0) && !played.contains(HomeKeys.recording($0)) }.map { HomeItem.make($0) }
            guard items.count >= HomeEngine.minItems else { continue }
            out.append(HomeSection(id: "genrePicks-" + MusicLibraryFacets.foldKey(g), kind: .genrePicks, title: wording.f("More %@", g), reason: wording.f("Because you listen to %@", g), items: Array(items.prefix(16))))
        }
        if !out.isEmpty, !Task.isCancelled { genreShelvesCache = (key, Date(), out) }
        return out
    }

    private static var playlistsCache: (key: String, at: Date, items: [HomeItem])?

    /// Playlists that feature the artists the person plays most: the active source is searched for each of the top three artists.
    static func playlistsForYou(hub: MusicHub, taste: HomeTaste) async -> [HomeItem] {
        let seeds = Array(taste.artists.prefix(3))
        let names = seeds.map(\.name)
        guard !names.isEmpty, let source = hub.registry.activeMetadata else { return [] }
        let key = source.id + "|" + names.joined(separator: ",")
        if let c = playlistsCache, c.key == key, Date().timeIntervalSince(c.at) < searchLifetime { return c.items }
        var out: [HomeItem] = []
        for seed in seeds {
            let n = seed.name
            let page = try? await MusicStreamResolver.withDeadline(searchDeadline) { try await source.searchPlaylists(n, page: nil) }
            let refs = taste.refs(for: seed, followed: hub.library.followedArtists)
            for pl in (page?.items ?? []).filter({ !$0.thumbnails.isEmpty }).prefix(5) where !out.contains(where: { $0.id == "playlist:" + HomeKeys.provider(pl.uid) }) {
                var item = HomeItem.make(pl)
                item.artistKey = MusicText.normalize(n)
                item.seedArtists = refs
                out.append(item)
            }
        }
        if !out.isEmpty, !Task.isCancelled { playlistsCache = (key, Date(), out) }
        return out
    }

    /// A sample of songs from the person's own music folders (none when Local files is off or no folder is added).
    /// 80 of the person's own files, drawn with the visit's seed: the same seed gives the same sample, so a recompose of the same page does not reshuffle this shelf.
    static func localSample(hub: MusicHub, seed: UInt64) async -> [MusicTrack] {
        guard hub.registry.isEnabled(MusicStatsRules.localProviderID), let local = hub.registry.provider(id: MusicStatsRules.localProviderID) as? LocalFilesProvider else { return [] }
        let entries = await LocalLibraryStore.shared.currentIndex().entries
        guard entries.count >= 4 else { return [] }
        var rng = HomeRandom.child(of: seed, "local-sample")
        return entries.shuffled(using: &rng).prefix(80).map { local.track($0) }
    }
}
