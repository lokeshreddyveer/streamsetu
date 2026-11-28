import Foundation
import Observation

// "Hide recommendation": songs and artists the person never wants suggested. It is not Never Play (the song still plays when asked for) and not a dislike
// (nothing is sent to a service): Home, Radio and autoplay simply leave it out of what they offer. The rules are plain values so they are tested alone.

struct MusicHiddenSet: Codable, Equatable, Sendable {
    /// Song uids.
    var tracks: Set<String> = []
    /// Artist ids (or the normalised name for an artist a source gave no id).
    var artists: Set<String> = []
    /// The normalised names of the hidden artists, always: `artists` holds the source's id when there is one, but a shelf that only has a name (a person tile from the graph)
    /// needs the name to match. Added later, so an older saved set reads without it.
    var names: Set<String> = []

    var isEmpty: Bool { tracks.isEmpty && artists.isEmpty }

    init(tracks: Set<String> = [], artists: Set<String> = [], names: Set<String> = []) { self.tracks = tracks; self.artists = artists; self.names = names }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decodeIfPresent(Set<String>.self, forKey: .tracks) ?? []
        artists = try c.decodeIfPresent(Set<String>.self, forKey: .artists) ?? []
        names = try c.decodeIfPresent(Set<String>.self, forKey: .names) ?? []
    }
    private enum CodingKeys: String, CodingKey { case tracks, artists, names }

    static func artistKey(_ a: MusicArtistRef) -> String { a.id.isEmpty ? MusicText.normalize(a.name) : a.id }

    func hides(_ t: MusicTrack) -> Bool {
        tracks.contains(t.uid) || t.artists.contains { artists.contains(Self.artistKey($0)) }
    }

    func hides(_ item: HomeItem) -> Bool {
        if let t = item.track { return hides(t) }
        // An artist card, an album or a playlist is hidden by the artist behind it: by id when the source gave one, else by name.
        if let a = item.artist, artists.contains(a.id) || artists.contains(MusicText.normalize(a.name)) { return true }
        if let al = item.album, al.artists.contains(where: { artists.contains(Self.artistKey($0)) }) { return true }
        // A card found for an artist (a playlist that features them) goes with that artist, whether they were hidden by an id or by their name.
        if let seeds = item.seedArtists, seeds.contains(where: { artists.contains(Self.artistKey($0)) || artists.contains(MusicText.normalize($0.name)) }) { return true }
        return !item.artistKey.isEmpty && artists.contains(item.artistKey)
    }

    /// A mix is a list of songs inside one tile: a hidden song is taken out of it, and a mix left too short to be a mix goes.
    private func withoutHiddenSongs(_ item: HomeItem) -> HomeItem? {
        guard item.kind == .mix, !item.mixTracks.isEmpty else { return item }
        var i = item
        i.mixTracks = filter(item.mixTracks)
        return i.mixTracks.count >= HomeMixes.minTracks ? i : nil
    }

    func filter(_ list: [MusicTrack]) -> [MusicTrack] { isEmpty ? list : list.filter { !hides($0) } }

    func filter(_ items: [HomeItem]) -> [HomeItem] { isEmpty ? items : items.filter { !hides($0) } }

    /// The feed without anything hidden. A shelf left with nothing is dropped.
    func filter(_ feed: HomeFeed) -> HomeFeed {
        guard !isEmpty else { return feed }
        var out = feed
        out.sections = feed.sections.compactMap { s in
            if s.kind == .graph { return s }   // the films-and-people block is drawn from the graph, not from this section's (empty) items
            var s = s
            let before = s.items.count
            s.items = filter(s.items).compactMap(withoutHiddenSongs)
            // A shelf that lost something and is now below the size a shelf needs goes; one that lost nothing is left as the engine made it.
            return s.items.isEmpty || (s.items.count < before && s.items.count < HomeEngine.minItems) ? nil : s
        }
        out.topTracks = filter(feed.topTracks)
        if out.topTracks.count < feed.topTracks.count, out.topTracks.count < HomeEngine.topTracksMin { out.topTracks = [] }   // a short list is no longer a top list
        if let h = feed.hero, hides(h.item) { out.hero = nil }
        return out
    }

    /// What Radio and autoplay treat as blocked, next to the person's own block list.
    var blockedKeys: Set<String> { tracks.union(artists) }
}

@MainActor @Observable
final class MusicHiddenRecommendations {
    static let shared = MusicHiddenRecommendations()
    private static let key = "music.hiddenRecommendations"

    private(set) var set: MusicHiddenSet
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(MusicHiddenSet.self, from: d) { set = s } else { set = MusicHiddenSet() }
    }

    func isHidden(_ t: MusicTrack) -> Bool { set.hides(t) }
    func isHidden(artist a: MusicArtistRef) -> Bool { set.artists.contains(MusicHiddenSet.artistKey(a)) }

    func hide(_ t: MusicTrack) { set.tracks.insert(t.uid); save() }
    func hide(artist a: MusicArtistRef) { set.artists.insert(MusicHiddenSet.artistKey(a)); set.names.insert(MusicText.normalize(a.name)); save() }
    func show(_ t: MusicTrack) { set.tracks.remove(t.uid); save() }
    func show(artist a: MusicArtistRef) { set.artists.remove(MusicHiddenSet.artistKey(a)); set.names.remove(MusicText.normalize(a.name)); save() }
    func clear() { set = MusicHiddenSet(); save() }

    private func save() {
        if set.isEmpty { defaults.removeObject(forKey: Self.key) } else if let d = try? JSONEncoder().encode(set) { defaults.set(d, forKey: Self.key) }
    }
}
