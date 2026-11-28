import Foundation

// Section B in pure form: the song rows of the page. The rows a person can play come from the PROVIDER's tracklist (that is the data the Play button
// uses, so it works the moment the page opens, whatever the metadata layer has or has not learned yet). The graph refines the rows in place (singer
// names, the recording id a row opens) and is the fallback list when no provider tracklist exists.

/// The few facts of a provider track the rows need (the page maps `MusicTrack` to this).
struct MusicSoundtrackTrackLite: Hashable, Sendable {
    var uid: String
    var title: String
    var durationMs: Int64
    var artistLine: String
    var disc: Int?
    var number: Int?
    var explicit: Bool = false
}

struct MusicSoundtrackSongRow: Hashable, Sendable, Identifiable {
    /// The recording the row opens as Song details (route `.song`).
    var id: MusicEntityID
    var title: String
    var durationMs: Int64
    var number: Int
    var disc: Int?
    /// Singers: from the graph when it knows them, else the provider's artist line.
    var singerLine: String
    /// The provider track behind the row (nil for a graph-only row, which cannot be played from here).
    var trackUID: String?
    var explicit: Bool
    /// Set when another row of the same album carries the same song title (a repeat on another edition, a version with its own recording): the rows stay
    /// separate and each says which one it is. Never set for a title that appears once.
    var edition: MusicSoundtrackEdition?
    var isPlayable: Bool { trackUID != nil }
}

/// Which of several same-titled rows this is.
enum MusicSoundtrackEdition: Hashable, Sendable {
    /// The version the title itself names in brackets, for example "Soul Version".
    case named(String)
    /// The nth row of the same title (2 for the second "Kashmeeru").
    case repeated(Int)
}

enum MusicSoundtrackSongs {
    /// Marks rows whose song title (without a bracketed version) appears more than once. Rows are never merged or dropped.
    static func markEditions(_ rows: [MusicSoundtrackSongRow]) -> [MusicSoundtrackSongRow] {
        func base(_ t: String) -> String {
            var s = t
            if let open = s.firstIndex(of: "("), s.hasSuffix(")") { s = String(s[..<open]) }
            return MusicGraphText.latin(s.trimmingCharacters(in: .whitespaces))
        }
        var groups: [String: [Int]] = [:]
        for (i, r) in rows.enumerated() { groups[base(r.title), default: []].append(i) }
        var out = rows
        for (_, idx) in groups where idx.count > 1 {
            let plain = idx.filter { !(rows[$0].title.contains("(") && rows[$0].title.hasSuffix(")")) }
            for i in idx where !plain.contains(i) {
                let t = rows[i].title
                if let open = t.firstIndex(of: "(") { out[i].edition = .named(String(t[t.index(after: open)..<t.index(before: t.endIndex)])) }
            }
            if plain.count > 1 { for (n, i) in plain.enumerated() { out[i].edition = .repeated(n + 1) } }
        }
        return out
    }

    /// The rows: one per provider track, in the provider's order, each tied to the recording the graph mints for that track (a pure function of its uid,
    /// so no database read is needed to open it). With no provider tracks the graph's own recordings are listed (not playable from this page).
    static func rows(provider: [MusicSoundtrackTrackLite], recordings: [MusicSoundtrackRecording], singers: [MusicEntityID: [String]], resolved: [MusicEntityID: String] = [:]) -> [MusicSoundtrackSongRow] {
        if !provider.isEmpty {
            return markEditions(provider.enumerated().map { i, t in
                let rid = MusicEntityID.provisional(kind: .recording, providerUID: t.uid)
                let line = singers[rid].map { $0.joined(separator: ", ") } ?? t.artistLine
                return MusicSoundtrackSongRow(id: rid, title: t.title, durationMs: t.durationMs, number: t.number ?? i + 1, disc: t.disc, singerLine: line, trackUID: t.uid, explicit: t.explicit)
            })
        }
        return markEditions(recordings.enumerated().map { i, r in
            MusicSoundtrackSongRow(id: r.id, title: r.title, durationMs: Int64(r.durationMs ?? 0), number: r.position ?? i + 1, disc: r.disc,
                                   singerLine: (singers[r.id] ?? []).joined(separator: ", "), trackUID: resolved[r.id], explicit: false)
        })
    }

    /// The tracks not yet listed, in order. A uid repeated inside one page is kept once too, so row ids (derived from the uid) never repeat.
    static func unseen(_ items: [MusicTrack], seen: inout Set<String>) -> [MusicTrack] {
        items.filter { seen.insert($0.uid).inserted }
    }

    /// `jiosaavn:abc123` as (provider, id). The provider id never contains a colon; the item id may.
    static func parse(uid: String) -> (provider: String, id: String)? {
        guard let colon = uid.firstIndex(of: ":") else { return nil }
        let p = String(uid[..<colon]), i = String(uid[uid.index(after: colon)...])
        return p.isEmpty || i.isEmpty ? nil : (p, i)
    }

    /// The provider album behind the opened entity: its own `provider` id first, then those of its parent album or editions.
    /// Every provider id in the family is tried in order; with `enabled` given, the first one whose source is switched on wins (nil only when none is).
    static func providerAlbum(_ r: MusicSoundtrackReader, family: MusicSoundtrackFamily, enabled: Set<String>? = nil) async -> (provider: String, id: String)? {
        await providerAlbums(r, family: family, enabled: enabled).first
    }

    /// Every provider id in the family whose source is on, in order: when the first source cannot give the songs, the next one is asked.
    static func providerAlbums(_ r: MusicSoundtrackReader, family: MusicSoundtrackFamily, enabled: Set<String>? = nil) async -> [(provider: String, id: String)] {
        var out: [(provider: String, id: String)] = []
        for m in family.members {
            for x in (try? await r.store.externalIDs(of: m)) ?? [] where x.scheme == .provider {
                if let p = parse(uid: x.value), enabled?.contains(p.provider) ?? true, !out.contains(where: { $0.provider == p.provider && $0.id == p.id }) { out.append(p) }
            }
        }
        return out
    }

    /// Groups rows under "Disc N" only when the songs carry more than one disc number.
    static func discs(_ rows: [MusicSoundtrackSongRow]) -> [(disc: Int?, rows: [MusicSoundtrackSongRow])] {
        let groups = MusicAlbumTrackView.discs(rows) { $0.disc }
        return groups.map { ($0.disc, $0.items) }
    }
}
