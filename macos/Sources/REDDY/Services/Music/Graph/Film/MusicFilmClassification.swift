import Foundation

/// Which film industry a film belongs to, from what the film itself records: its language and where it was made. Nothing is guessed from the title or the cast.
/// A film in a language with no named industry has none, and a film made outside India is not placed in an Indian industry by its language alone.
struct MusicFilmIndustry: Equatable, Sendable {
    enum Basis: Equatable, Sendable { case languageAndCountry, languageOnly }
    var name: String
    /// The name as the person reads it (their app language); `name` is the stable English one.
    var title: String { Localized.string(name) }
    var basis: Basis

    private static let byLanguage: [String: String] = [
        "te": "Tollywood", "ta": "Kollywood", "hi": "Bollywood", "ml": "Mollywood", "kn": "Sandalwood",
        "bn": "Bengali cinema", "pa": "Pollywood", "mr": "Marathi cinema", "gu": "Dhollywood", "or": "Ollywood", "as": "Assamese cinema", "bho": "Bhojpuri cinema", "bh": "Bhojpuri cinema"
    ]

    /// The industry name a language usually stands for (nil for none). The one table: the film page and Combine both read it.
    static func name(forLanguageCode code: String) -> String? {
        let key = MusicCombineRules.languageKey(code)
        return byLanguage[key] ?? byLanguage[String(code.lowercased().prefix(3))]
    }

    private static func isIndia(_ country: String) -> Bool {
        let c = country.trimmingCharacters(in: .whitespaces).lowercased()
        return c == "in" || c == "ind" || c == "india"
    }

    static func classify(language: String?, country: String?) -> MusicFilmIndustry? {
        guard let language, !language.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let key = MusicCombineRules.languageKey(language)
        let name = byLanguage[key] ?? byLanguage[String(language.lowercased().prefix(3))]
        guard let name else { return nil }
        if let country, !country.trimmingCharacters(in: .whitespaces).isEmpty {
            return isIndia(country) ? MusicFilmIndustry(name: name, basis: .languageAndCountry) : nil
        }
        return MusicFilmIndustry(name: name, basis: .languageOnly)
    }
}

/// A person is a playback singer for a film when the film credits them as a singer and does not credit them in its cast. The same person can be a playback singer
/// in one film and an acting singer in another.
enum MusicPlaybackSinger {
    static func isPlayback(inFilm castIDs: Set<MusicEntityID>, singer: MusicEntityID) -> Bool { !castIDs.contains(singer) }

    /// Splits a singer's films into those where they only sang and those where they also appear in the cast.
    static func split(films: [(film: MusicEntityID, cast: Set<MusicEntityID>)], singer: MusicEntityID) -> (playback: [MusicEntityID], acting: [MusicEntityID]) {
        var playback: [MusicEntityID] = [], acting: [MusicEntityID] = []
        for f in films { if f.cast.contains(singer) { acting.append(f.film) } else if !f.cast.isEmpty { playback.append(f.film) } }
        return (playback, acting)
    }
}

/// The kind of music a song belongs to, from tags a source documents (a genre, a tag, a Wikidata class). A song with no such tag has no kind: it is not
/// called devotional or folk because of its title or its singer.
enum MusicSongKind: String, CaseIterable, Sendable {
    case devotional, festival, folk, filmScore, classicalFusion, classical

    private static let words: [MusicSongKind: [String]] = [
        .devotional: ["devotional", "bhajan", "bhakti", "kirtan", "stotra", "aarti", "qawwali", "gospel", "hymn", "keerthana", "keertana"],
        .festival: ["festival", "diwali", "deepavali", "holi", "navratri", "ganesh", "ugadi", "pongal", "onam", "eid", "christmas", "lohri", "bihu", "vinayaka"],
        .folk: ["folk", "janapada", "lavani", "baul", "bhangra", "garba", "villupattu", "therukoothu", "lok geet", "loknath"],
        .filmScore: ["score", "background score", "film score", "bgm", "original score", "incidental music"],
        .classicalFusion: ["classical fusion", "carnatic fusion", "hindustani fusion", "indo-jazz", "raga fusion", "raga rock"],
        .classical: ["carnatic", "hindustani", "classical", "dhrupad", "khayal", "thumri", "ghazal", "varnam", "kriti"]
    ]

    /// Every kind the given tags document. Tags are compared whole-word, so "folklore" is not "folk".
    static func kinds(fromTags tags: [String]) -> Set<MusicSongKind> {
        var out = Set<MusicSongKind>()
        for tag in tags {
            let t = " " + MusicText.normalize(tag) + " "
            for (kind, ws) in words where ws.contains(where: { t.contains(" " + MusicText.normalize($0) + " ") }) { out.insert(kind) }
        }
        // Classical alone is not fusion; fusion that names a tradition counts as both.
        return out
    }
}
