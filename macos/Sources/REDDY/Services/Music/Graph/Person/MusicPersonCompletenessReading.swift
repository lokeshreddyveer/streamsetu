import Foundation

extension MusicPersonReader {
    /// One entry per album, however many editions and sources named it. A provider's `release` that is an edition of an album stands for that album; two
    /// entries that are the same album by title, language and year (no `editionOf` link yet) are shown once, the album concept and the one with a cover
    /// preferred. Nothing is merged in the graph here: this only decides what the page lists.
    func collapseEditions(_ entries: [MusicPersonEntry]) async -> [MusicPersonEntry] {
        var lifted: [MusicPersonEntry] = []
        for e in entries {
            guard e.kind == .release, let up = await outgoing(e.id).first(where: { $0.predicate == .editionOf && !$0.tombstone }), let a = await snapshot(up.object) else { lifted.append(e); continue }
            var m = MusicPersonEntry(snapshot: a)
            m.count = e.count; m.status = e.status; m.confidence = e.confidence; m.billing = e.billing; m.detail = e.detail; m.roles = e.roles
            m.filmID = e.filmID; m.filmTitle = e.filmTitle; m.filmYear = e.filmYear; m.reason = e.reason; m.versionKind = e.versionKind
            if m.imageRef == nil { m.imageRef = e.imageRef }
            lifted.append(m)
        }
        var out: [MusicPersonEntry] = []
        var keys: [(key: String, lang: String?, class: String, index: Int)] = []
        for e in lifted {
            guard [.album, .release].contains(e.kind) else { out.append(e); continue }
            let p = MusicPersonWorkKey.parse(e.name)
            let lang = e.lang ?? p.lang
            let cls = ["single", "ep"].contains(e.subkind ?? "") ? "small" : "album"
            if let hit = keys.first(where: { $0.key == p.key && !p.key.isEmpty && $0.class == cls && MusicPersonWorkKey.langsCompatible($0.lang, lang) && MusicPersonWorkKey.yearsCompatible(out[$0.index].year, e.year, tolerance: 2) }) {
                if Self.preferred(e, over: out[hit.index]) {
                    var winner = e
                    if winner.imageRef == nil { winner.imageRef = out[hit.index].imageRef }
                    if winner.filmID == nil { winner.filmID = out[hit.index].filmID; winner.filmTitle = out[hit.index].filmTitle; winner.filmYear = out[hit.index].filmYear; winner.reason = out[hit.index].reason }
                    out[hit.index] = winner
                } else if out[hit.index].imageRef == nil {
                    out[hit.index].imageRef = e.imageRef
                }
                continue
            }
            keys.append((p.key, lang, cls, out.count))
            out.append(e)
        }
        return Self.unique(out)
    }

    /// The entry the page keeps when two are the same album: an album concept over a release, a verified credit, a cover, then the stable id.
    static func preferred(_ a: MusicPersonEntry, over b: MusicPersonEntry) -> Bool {
        if (a.kind == .album) != (b.kind == .album) { return a.kind == .album }
        if (a.status == .verified) != (b.status == .verified) { return a.status == .verified }
        if (a.imageRef != nil) != (b.imageRef != nil) { return a.imageRef != nil }
        return a.id < b.id
    }
}
