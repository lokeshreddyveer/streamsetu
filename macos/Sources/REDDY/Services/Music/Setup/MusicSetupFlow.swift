import Foundation

enum MusicSetupStep: Int, CaseIterable, Sendable { case languages, genres, artists, extras }

/// The first-run "tell Music what you like" flow as plain values: the steps, the person's picks, and how the picks join their taste preferences. No screen, no network.
/// Every step can be skipped and nothing is required; the picks shape Recently Added, Radio and autoplay, and songs in a genre marked "not for me" are left out of them.
struct MusicSetupFlow: Equatable, Sendable {
    var step: MusicSetupStep = .languages
    var languages: Set<String> = []
    var genres: Set<String> = []
    var lovedGenres: Set<String> = []
    var dislikedGenres: Set<String> = []
    var artists: [MusicArtist] = []

    /// True for a flow that started from the saved choices: it then is the whole picture, so what it no longer holds is removed on Done.
    private(set) var startedFromSaved = false
    init() {}
    /// A flow that starts from what is already saved, so redoing the setup shows the person's earlier choices (including "not for me") and lets them change or clear each one.
    init(prefs: MusicTastePrefs) {
        languages = prefs.languages; genres = prefs.genres; lovedGenres = prefs.lovedGenres; dislikedGenres = prefs.dislikedGenres; artists = prefs.artists
        startedFromSaved = true
    }

    /// The genres offered. A fixed vocabulary of common labels (a new person has no library to derive them from); they are matched to a song's genre tags by name.
    static let genreVocabulary: [String] = ["Pop", "Rock", "Hip-Hop", "Dance", "Electronic", "Classical", "Carnatic", "Hindustani", "Devotional", "Folk", "Ghazal", "Indie",
                                            "Jazz", "R&B", "Soundtrack", "Latin", "K-Pop", "Lo-fi", "Country", "Metal"]

    mutating func toggleLanguage(_ code: String) { if languages.contains(code) { languages.remove(code) } else { languages.insert(code) } }
    enum GenreState: Equatable, Sendable { case none, liked, loved, notForMe }
    func state(of g: String) -> GenreState { lovedGenres.contains(g) ? .loved : (genres.contains(g) ? .liked : (dislikedGenres.contains(g) ? .notForMe : .none)) }
    /// One tap: like, or take the like away. Double tap: love. Long press: not for me. Each one replaces the genre's earlier state.
    mutating func toggleGenre(_ g: String) { let s = state(of: g); clear(g); if s == .none || s == .notForMe { genres.insert(g) } }
    mutating func loveGenre(_ g: String) { let s = state(of: g); clear(g); if s != .loved { genres.insert(g); lovedGenres.insert(g) } }
    mutating func rejectGenre(_ g: String) { let s = state(of: g); clear(g); if s != .notForMe { dislikedGenres.insert(g) } }
    private mutating func clear(_ g: String) { genres.remove(g); lovedGenres.remove(g); dislikedGenres.remove(g) }
    mutating func toggleArtist(_ a: MusicArtist) {
        if let i = artists.firstIndex(where: { $0.uid == a.uid }) { artists.remove(at: i) } else { artists.append(a) }
    }
    func hasArtist(_ a: MusicArtist) -> Bool { artists.contains { $0.uid == a.uid } }

    /// True when nothing at all is picked, a genre marked "not for me" included (Done saves those too).
    var pickedNothing: Bool { languages.isEmpty && genres.isEmpty && lovedGenres.isEmpty && dislikedGenres.isEmpty && artists.isEmpty }

    var isFirst: Bool { step == MusicSetupStep.allCases.first }
    var isLast: Bool { step == MusicSetupStep.allCases.last }
    mutating func next() { if let n = MusicSetupStep(rawValue: step.rawValue + 1) { step = n } }
    mutating func back() { if let p = MusicSetupStep(rawValue: step.rawValue - 1) { step = p } }
    var progress: Double { Double(step.rawValue + 1) / Double(MusicSetupStep.allCases.count) }

    /// The preferences after the picks are added: earlier choices stay, except that a genre has one state at a time, so the newest pick for a genre replaces its older state
    /// (a genre once marked "not for me" and now liked is no longer disliked).
    func applying(to prefs: MusicTastePrefs) -> MusicTastePrefs {
        var p = prefs
        if startedFromSaved {
            p.languages = languages; p.genres = genres; p.lovedGenres = lovedGenres; p.dislikedGenres = dislikedGenres; p.artists = artists
            return p
        }
        p.languages.formUnion(languages)
        p.dislikedGenres.subtract(genres); p.dislikedGenres.subtract(lovedGenres)
        p.genres.formUnion(genres)
        p.genres.formUnion(lovedGenres); p.lovedGenres.formUnion(lovedGenres)
        p.lovedGenres.subtract(dislikedGenres)
        p.dislikedGenres.formUnion(dislikedGenres)
        p.genres.subtract(dislikedGenres)
        for a in artists where !p.artists.contains(where: { $0.uid == a.uid }) { p.artists.append(a) }
        return p
    }

    /// Artists to offer, from the songs a source lists for the chosen languages: the ones that appear most come first, an artist already picked or already liked is left out,
    /// and "Various Artists" or an unknown name is never offered. Real data only: nothing here is a hand-typed list of names.
    static func suggestedArtists(fromTracks tracks: [MusicTrack], excluding: Set<String> = [], limit: Int = 24) -> [MusicArtist] {
        struct Acc { var artist: MusicArtist; var count: Int; var first: Int }
        var acc: [String: Acc] = [:]
        for (i, t) in tracks.enumerated() {
            for ref in t.artists where !ref.id.isEmpty {
                let name = MusicText.normalize(ref.name)
                if name.isEmpty || name == "various artists" || name == "unknown artist" || excluding.contains(name) { continue }
                // Keyed by the artist's id, not the name, so two artists with one name stay two. A song's cover is the album's art, not the artist's portrait, so none is borrowed.
                let artist = MusicArtist(id: ref.id, providerID: t.providerID, name: ref.name, thumbnails: [])
                if var a = acc[artist.uid] { a.count += 1; acc[artist.uid] = a }
                else { acc[artist.uid] = Acc(artist: artist, count: 1, first: i) }
            }
        }
        var rows: [Acc] = []
        for a in acc.values { rows.append(a) }
        rows.sort { (x: Acc, y: Acc) -> Bool in x.count != y.count ? x.count > y.count : x.first < y.first }
        var out: [MusicArtist] = []
        for r in rows.prefix(limit) { out.append(r.artist) }
        return out
    }
}

/// Whether to offer the setup. A new person (no taste choices, no plays, no likes) gets the full flow once; a person who already listens gets a quiet card instead,
/// never a forced screen. Either goes away once the person has finished or said "not now".
enum MusicSetupGate {
    static let doneKey = "music.setup.done"
    static let dismissedKey = "music.setup.cardDismissed"

    enum Offer: Equatable, Sendable { case none, fullFlow, quietCard }

    static func offer(setupDone: Bool, cardDismissed: Bool, prefs: MusicTastePrefs, plays: Int, likes: Int) -> Offer {
        if setupDone { return .none }
        let isNew = prefs.isEmpty && plays == 0 && likes == 0
        if isNew { return .fullFlow }
        return cardDismissed ? .none : .quietCard
    }
}
