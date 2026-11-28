import Foundation

/// The language of a song when its source does not say and its title does not show it (a title in Latin letters, which is most songs): read from what the graph holds about the
/// song itself, else about the film or album it is on. Nothing here depends on a country, a language list or an artist; a song the graph knows nothing about has no language.
enum MusicGraphLanguage {
    /// The language of each track by uid (only the tracks whose language could be found). Stated language and non-Latin script come first and need no graph read.
    static func languages(of tracks: [MusicTrack], store: any MusicGraphStoring) async -> [String: MusicLanguage] {
        var out: [String: MusicLanguage] = [:]
        for t in tracks {
            if Task.isCancelled { break }
            if out[t.uid] != nil { continue }
            if let l = MusicLanguageDetector.language(of: t), l != .latin { out[t.uid] = l; continue }
            if let l = await fromGraph(t, store: store) { out[t.uid] = l }
        }
        return out
    }

    private static func fromGraph(_ t: MusicTrack, store: any MusicGraphStoring) async -> MusicLanguage? {
        let id = MusicEntityID.provisional(kind: .recording, providerUID: t.uid)
        let resolved = (try? await store.resolve(id)) ?? id
        guard let snap = try? await store.entity(resolved) else { return nil }
        if let l = snap.lang.flatMap({ MusicLanguage(stated: $0) }) { return l }
        // The film the song is in, or the album it is on (and that album's film).
        for p in [MusicPredicate.featuredIn, .trackOn] {
            for e in ((try? await store.edges(of: resolved, predicate: p, direction: .outgoing, limit: 4)) ?? []) {
                if let s = try? await store.entity(e.object), let l = s.lang.flatMap({ MusicLanguage(stated: $0) }) { return l }
                if p == .trackOn {
                    for f in ((try? await store.edges(of: e.object, predicate: .soundtrackOf, direction: .outgoing, limit: 2)) ?? []) {
                        if let s = try? await store.entity(f.object), let l = s.lang.flatMap({ MusicLanguage(stated: $0) }) { return l }
                    }
                }
            }
        }
        return nil
    }
}
