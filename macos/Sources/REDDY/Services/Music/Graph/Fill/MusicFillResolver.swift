import Foundation

// Turns roster entries and graph ids into tiles with whatever the graph already knows (picture, year, a works count), and says which ones still
// need the completeness pass. Reads are bounded and local; nothing here calls the network.

/// What a build returns: the shelves, and the entities whose picture or works the graph lacks (the completeness pass asks for them).
struct MusicFillResult: Sendable {
    var shelves: [MusicFillShelf]
    var needsCompleteness: [MusicEntityID]
    static let empty = MusicFillResult(shelves: [], needsCompleteness: [])
}

struct MusicFillResolver: Sendable {
    let store: any MusicGraphStoring
    let wording: MusicFillWording
    init(store: any MusicGraphStoring, wording: MusicFillWording = .english) { self.store = store; self.wording = wording }

    /// A tile for a graph entity the person met (a composer they play, a film). `caption` overrides the context line.
    func tile(_ id: MusicEntityID, kind: MusicFillTileKind, role: MusicRole? = nil, caption: String? = nil) async -> (tile: MusicFillTile, needs: Bool)? {
        let live = (try? await store.resolve(id)) ?? id
        guard let s = try? await store.entity(live), s.state == .live, !MusicLinkMatrix.isVariousArtists(s.name) else { return nil }
        if kind == .film, MusicFranchise.isFranchise(s.subkind) { return nil }
        let line = caption ?? MusicFillLine.join([kindLabel(kind), MusicFillLanguage.name(s.lang), s.year.map { kind == .film || kind == .album || kind == .soundtrack ? String($0) : (MusicFillLine.decade($0) ?? "") }])
        let title = kind == .film ? MusicFillLine.filmCaption(s.name, year: s.year) : s.name
        return (MusicFillTile(entity: s.id, kind: kind, title: title, subtitle: line, imageRef: s.imageRef, role: role, year: s.year), s.imageRef == nil)
    }

    func kindLabel(_ k: MusicFillTileKind) -> String {
        switch k {
        case .musicDirector: wording.s("Music director")
        case .singer: wording.s("Singer")
        case .lyricist: wording.s("Lyricist")
        case .actor: wording.s("Actor")
        case .person: wording.s("Artist")
        case .film: wording.s("Film")
        case .soundtrack: wording.s("Soundtrack")
        case .album: wording.s("Album")
        case .song: wording.s("Song")
        case .playlist: wording.s("Playlist")
        case .language: wording.s("Language")
        case .era: wording.s("Era")
        case .mood: wording.s("Mood")
        case .genre: wording.s("Genre")
        case .region: wording.s("Region")
        case .station: wording.s("Radio")
        }
    }

    func tileKind(of link: MusicConnection) -> MusicFillTileKind {
        switch link.kind {
        case .musicDirector: .musicDirector
        case .singer: .singer
        case .lyricist: .lyricist
        case .actor: .actor
        case .artist: .person
        case .film: .film
        case .soundtrack: .soundtrack
        case .album: .album
        case .song: .song
        case .playlist: .playlist
        case .radio: .station
        }
    }

    /// A tile for a link of a link set.
    func tile(_ link: MusicConnection, caption: String? = nil) -> MusicFillTile {
        let kind = tileKind(of: link)
        let title = kind == .film ? MusicFillLine.filmCaption(link.name, year: link.year) : link.name
        let line = caption ?? MusicFillLine.join([kindLabel(kind), link.count > 1 ? wording.f("%@ songs", String(link.count)) : nil])
        return MusicFillTile(entity: link.target, kind: kind, title: title, subtitle: line, imageRef: link.imageRef, role: link.role, year: link.year)
    }
}
