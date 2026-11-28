import Foundation

extension MusicPersonReader {
    static let songKinds: Set<MusicEntityKind> = [.recording, .track, .work]
    static let albumKinds: Set<MusicEntityKind> = [.album, .release]
    static let filmKinds: Set<MusicEntityKind> = [.film, .series]

    /// Albums a person is credited on, plus the releases their credited songs sit on, split into albums and singles/EPs.
    func releases(view: MusicPersonView, songs: [(snap: MusicEntitySnapshot, edge: MusicEdge)], cap: Int) async -> (albums: [MusicPersonEntry], singles: [MusicPersonEntry]) {
        var found: [MusicEntityID: (MusicEntitySnapshot, MusicEdge?, Int)] = [:]
        for (s, e) in await works(view: view, kinds: Self.albumKinds, cap: cap) { found[s.id] = (s, e, 1) }
        for (s, _) in songs.prefix(30) {
            for t in await outgoing(s.id) where t.predicate == .trackOn {
                if let cur = found[t.object] { found[t.object] = (cur.0, cur.1, cur.2 + 1) }
                else if found.count < cap * 2, let r = await snapshot(t.object) { found[t.object] = (r, nil, 1) }
            }
        }
        let entries = await collapseEditions(found.values.map { (s, e, n) -> MusicPersonEntry in var x = entry(s, edge: e); x.count = n; return x }).sorted(by: Self.newestFirst)
        let isSingle: (MusicPersonEntry) -> Bool = { ["single", "ep"].contains($0.subkind ?? "") }
        return (entries.filter { !isSingle($0) }, entries.filter(isSingle))
    }

    /// SINGER: top songs, albums, singles, film songs, collaborations, composers worked with, languages, related artists, playlists, radio.
    func buildSinger(_ report: @escaping Report) async throws -> MusicPersonViewData {
        let view = MusicPersonView.singer
        var sections: [MusicPersonSection] = []
        let songs = await works(view: view, kinds: Self.songKinds, cap: Self.singerSongs)
        var topEntries = songs.map { entry($0.snap, edge: $0.edge) }
        sections.append(Self.cut(.topSongs, topEntries, to: Self.singerSongs))
        if let seed = topEntries.first { sections.append(MusicPersonSection(.radio, [seed])) }
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // stage 2: albums and singles, film songs
        let rel = await releases(view: view, songs: songs, cap: Self.albumCap)
        sections.append(Self.cut(.albums, rel.albums, to: Self.grid))
        sections.append(Self.cut(.singles, rel.singles, to: Self.grid))
        var filmSongs: [MusicPersonEntry] = []
        var playback: [MusicPersonEntry] = []
        var castCache: [MusicEntityID: Set<MusicEntityID>] = [:]
        // The films this person acted in, from their own credits: a film with more than 100 edges may not list the person among the first of them, and a singer-actor's own
        // on-screen songs would then read as playback singing.
        let actedIn = Set(await credits().filter { $0.predicate == .hasCast }.map(\.subject))
        for (i, s) in songs.prefix(Self.singerSongs).enumerated() {
            if Task.isCancelled { break }
            guard let link = await filmLink(of: s.snap.id), let film = await snapshot(link.film) else { continue }
            var e = entry(s.snap, edge: s.edge)
            e.filmID = film.id; e.filmTitle = film.name; e.filmYear = film.year; e.year = film.year ?? s.snap.year; e.reason = Self.reason(for: link, filmTitle: film.name)
            filmSongs.append(e)
            // Playback singing: the film's cast is on record and does not include this person. A film with no cast on record is not placed either way.
            if castCache[film.id] == nil { castCache[film.id] = Set(await outgoing(film.id).filter { $0.predicate == .hasCast }.map(\.object)) }
            if let cast = castCache[film.id], !cast.isEmpty, !cast.contains(person), !actedIn.contains(film.id) { playback.append(e) }
            if i < topEntries.count { topEntries[i].filmID = film.id; topEntries[i].filmTitle = film.name; topEntries[i].filmYear = film.year; topEntries[i].year = e.year }
        }
        filmSongs.sort(by: Self.newestFirst)
        sections[0] = Self.cut(.topSongs, topEntries, to: Self.singerSongs)
        sections.append(Self.cut(.filmSongs, filmSongs, to: Self.grid))
        playback.sort(by: Self.newestFirst)
        if !playback.isEmpty { sections.append(Self.cut(.playbackSongs, playback, to: Self.grid)) }
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // stage 3: people around the songs
        let workIDs = songs.prefix(Self.singerSongs).map(\.snap.id)
        let co = MusicCollaboration.rank(await observations(of: Array(workIDs), roles: view.roles, releaseLevel: false, filmLevel: false), excluding: [person], limit: 24)
        sections.append(Self.cut(.collaborations, await collaboratorEntries(co) { .sharedWorks($0.workCount) }, to: Self.shelf * 2))
        let comp = MusicCollaboration.rank(await observations(of: Array(workIDs), roles: MusicPersonView.composer.roles), excluding: [person], limit: 24)
        let compEntries = await collaboratorEntries(comp) { .sharedWorks($0.workCount) }
        sections.append(Self.cut(.composersWorkedWith, compEntries, to: Self.shelf * 2))
        sections.append(Self.cut(.languages, languages(songs.map(\.snap), albums: rel.albums + rel.singles), to: 12))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        // stage 4: related artists, playlists
        let related = await relatedSingers(composers: Array(comp.prefix(2)), excluding: [])
        sections.append(Self.cut(.relatedArtists, related, to: Self.shelf * 2))
        sections.append(Self.cut(.playlists, await playlists(of: Array(workIDs.prefix(30))), to: Self.shelf))
        return data(view, sections, complete: true)
    }

    /// Languages the person performed in, from the language each song and album carries (nothing is guessed from a title). Not navigable.
    func languages(_ songs: [MusicEntitySnapshot], albums: [MusicPersonEntry]) -> [MusicPersonEntry] {
        var counts: [String: Int] = [:]
        for s in songs { if let l = Self.languageCode(s.lang) { counts[l, default: 0] += 1 } }
        for a in albums { if let l = Self.languageCode(a.lang) { counts[l, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (code, n) in
            var e = MusicPersonEntry(id: .derive(kind: .language, aliasKey: code), name: Self.languageName(code), kind: .language)
            e.count = n; e.navigable = false; e.lang = code
            return e
        }
    }

    static func languageCode(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty, t.count <= 16 else { return nil }
        // The sources' words for "no language" are not languages.
        if ["xx", "und", "zxx", "mul", "mis", "zz", "00"].contains(t) { return nil }
        let map = ["bengali": "bn", "hin": "hi", "tel": "te", "tam": "ta", "mal": "ml", "kan": "kn", "eng": "en", "kor": "ko", "ben": "bn", "pan": "pa", "mar": "mr", "guj": "gu", "urd": "ur", "jpn": "ja", "spa": "es", "fra": "fr", "fre": "fr"]
        // A full name ("malayalam", "kannada") is looked up as a name: its first two letters are another language's code (ma, ka, be). A word that is neither a known name nor
        // a code is no language rather than a wrong one.
        return map[t] ?? MusicLanguageNames.code(forEnglishName: t) ?? (t.count <= 3 ? t : nil)
    }

    static func languageName(_ code: String) -> String {
        MusicLanguageNames.displayName(code: code)?.capitalized(with: Locale(identifier: Localized.activeCode)) ?? code.uppercased()
    }

    /// Singers who sang for the same top composers (two composers, twenty songs each): ranked by shared songs, plus stored `collaboratedWith` links.
    func relatedSingers(composers: [MusicCollaborator], excluding: Set<MusicEntityID>) async -> [MusicPersonEntry] {
        var obs: [MusicCreditObservation] = []
        for c in composers {
            if Task.isCancelled { break }
            var songs: [MusicEntityID] = []
            for p in [MusicPredicate.composedBy, .musicDirectedBy] { songs += await incoming(c.id, p, limit: 20).filter { Self.songKinds.contains($0.subject.kind) }.map(\.subject) }
            for w in Set(songs).sorted().prefix(20) {
                for e in await outgoing(w) where e.predicate == .performedBy && MusicPersonRoles.counts(e) && e.object.kind.isAgent && e.object != person {
                    if let r = MusicPersonRoles.effectiveRole(e), MusicPersonView.singer.roles.contains(r) {
                        obs.append(MusicCreditObservation(work: w, agent: e.object, role: r, level: .song, confidence: e.confidence))
                    }
                }
            }
        }
        let ranked = MusicCollaboration.rank(obs, excluding: excluding.union([person]), minCount: 2, limit: 16)
        var out = await collaboratorEntries(ranked) { .sharedComposers($0.workCount) }
        // Stored links (a source said they are similar): kept with their source named, after the computed ones.
        let stored = (await outgoing(person)).filter { $0.predicate == .collaboratedWith && $0.object.kind.isAgent && ($0.status == .verified || $0.confidence >= MusicPersonRoles.minConfidence) }
        for e in stored where !out.contains(where: { $0.id == e.object }) {
            if let s = await snapshot(e.object) { var x = MusicPersonEntry(snapshot: s); x.reason = .storedSimilar(e.attributes["attribution"] ?? ""); x.status = e.status; x.confidence = e.confidence; out.append(x) }
        }
        return out
    }

    /// Playlists that hold the person's songs (incoming `playlistContains`), most songs first.
    func playlists(of songs: [MusicEntityID]) async -> [MusicPersonEntry] {
        var counts: [MusicEntityID: Int] = [:]
        for s in songs {
            if Task.isCancelled { break }
            for e in await incoming(s, .playlistContains, limit: 10) where e.subject.kind == .playlist { counts[e.subject, default: 0] += 1 }
        }
        var out: [MusicPersonEntry] = []
        for (id, n) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(12) {
            if let s = await snapshot(id) { var e = MusicPersonEntry(snapshot: s); e.count = n; out.append(e) }
        }
        return out
    }
}
