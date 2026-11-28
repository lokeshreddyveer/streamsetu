import Foundation

/// The languages Home can tell apart, and the ones its regional sources can be asked for.
/// A song's language is, in this order: the language its SOURCE states (a provider field, see `MusicLanguageDetector.stated`), else the writing system of its
/// title, artist and album text (a weak guess that only works for non-Latin scripts), else nothing. A song written in Latin letters with no stated language
/// is counted as Latin script, never guessed to be Telugu or Hindi.
enum MusicLanguage: String, CaseIterable, Codable, Hashable, Sendable {
    case telugu, hindi, tamil, kannada, malayalam, bengali, punjabi, marathi, gujarati, english, spanish, korean, japanese, arabic, latin

    /// The languages of the Indian subcontinent that this list carries (their songs are looked up the same way).
    var isSouthAsian: Bool { [.telugu, .hindi, .tamil, .kannada, .malayalam, .bengali, .punjabi, .marathi, .gujarati].contains(self) }

    /// English name; the screen passes it through `Localized.string`.
    var englishName: String {
        switch self {
        case .telugu: "Telugu"
        case .hindi: "Hindi"
        case .tamil: "Tamil"
        case .kannada: "Kannada"
        case .malayalam: "Malayalam"
        case .bengali: "Bengali"
        case .punjabi: "Punjabi"
        case .marathi: "Marathi"
        case .gujarati: "Gujarati"
        case .english: "English"
        case .spanish: "Spanish"
        case .korean: "Korean"
        case .japanese: "Japanese"
        case .arabic: "Arabic"
        case .latin: "Latin script"
        }
    }

    var displayName: String { Localized.string(englishName) }

    /// The language's own name, for the Add language menu.
    var nativeName: String? {
        switch self {
        case .telugu: "తెలుగు"
        case .hindi: "हिन्दी"
        case .tamil: "தமிழ்"
        case .kannada: "ಕನ್ನಡ"
        case .malayalam: "മലയാളം"
        case .bengali: "বাংলা"
        case .punjabi: "ਪੰਜਾਬੀ"
        case .marathi: "मराठी"
        case .gujarati: "ગુજરાતી"
        case .korean: "한국어"
        case .japanese: "日本語"
        case .arabic: "العربية"
        case .spanish: "Español"
        case .english, .latin: nil
        }
    }

    /// How the menu names it: the native name first, then the name in the app's language ("తెలుగు, Telugu").
    var menuName: String { nativeName.map { $0 + ", " + displayName } ?? displayName }

    /// The writing system its songs use. Marathi shares Devanagari with Hindi, so the script cannot tell those two apart; the English and
    /// Spanish ones use Latin letters.
    var script: MusicLanguage {
        switch self {
        case .marathi: .hindi
        case .english, .spanish: .latin
        default: self
        }
    }

    /// The name the JioSaavn web API uses for this language in its language setting, or nil when it has no list for it.
    var jioSaavnCode: String? {
        switch self {
        case .telugu, .hindi, .tamil, .kannada, .malayalam, .bengali, .punjabi: rawValue
        default: nil
        }
    }

    /// The Apple chart country whose songs are mostly in this language, used with a script filter: the country the system itself says the language belongs to
    /// (its likely region, read from Locale). Nil for languages with their own lists on JioSaavn, for languages written in Latin letters (a script filter cannot cut them)
    /// and when Locale names no country.
    var chartCountry: String? {
        guard script != .latin, jioSaavnCode == nil, let code = MusicLanguageNames.code(forEnglishName: englishName) else { return nil }
        let full = Locale.Language(identifier: code).maximalIdentifier
        guard let region = Locale(identifier: full).region?.identifier, region.count == 2 else { return nil }
        return region.lowercased()
    }

    /// The language a source STATES in its own words ("telugu", "Hindi", or a two-letter code such as "te"). Nil when it names one this list does not have.
    init?(stated: String) {
        let w = stated.trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty else { return nil }
        let codes: [String: MusicLanguage] = ["te": .telugu, "hi": .hindi, "ta": .tamil, "kn": .kannada, "ml": .malayalam, "bn": .bengali, "pa": .punjabi, "mr": .marathi,
                                              "gu": .gujarati, "en": .english, "es": .spanish, "ko": .korean, "ja": .japanese, "ar": .arabic]
        if let c = codes[w] { self = c; return }
        guard let match = MusicLanguage.allCases.first(where: { $0 != .latin && ($0.rawValue == w || $0.englishName.lowercased() == w) }) else { return nil }
        self = match
    }

    /// The languages a person can pick by hand: every one but plain Latin script.
    static var pickable: [MusicLanguage] { allCases.filter { $0 != .latin } }
}

/// Finds the language of a piece of text from its writing system. Pure; no network and no word lists.
enum MusicLanguageDetector {
    private static let ranges: [(ClosedRange<UInt32>, MusicLanguage)] = [
        (0x0C00...0x0C7F, .telugu), (0x0C80...0x0CFF, .kannada), (0x0D00...0x0D7F, .malayalam), (0x0B80...0x0BFF, .tamil),
        (0x0980...0x09FF, .bengali), (0x0A00...0x0A7F, .punjabi), (0x0A80...0x0AFF, .gujarati), (0x0900...0x097F, .hindi),
        (0xAC00...0xD7AF, .korean), (0x1100...0x11FF, .korean), (0x3130...0x318F, .korean),
        (0x3040...0x309F, .japanese), (0x30A0...0x30FF, .japanese),
        (0x0600...0x06FF, .arabic), (0x0750...0x077F, .arabic), (0xFB50...0xFDFF, .arabic), (0xFE70...0xFEFF, .arabic)
    ]

    /// Letters per script. Latin letters are counted under `.latin`.
    static func scriptCounts(_ text: String) -> [MusicLanguage: Int] {
        var out: [MusicLanguage: Int] = [:]
        for u in text.unicodeScalars where u.properties.isAlphabetic {
            let v = u.value
            if let hit = ranges.first(where: { $0.0.contains(v) }) { out[hit.1, default: 0] += 1 }
            else if v < 0x250 { out[.latin, default: 0] += 1 }
        }
        return out
    }

    /// The language of the text: the commonest non-Latin script when there is one (a Telugu title with "(From ...)" in Latin letters is Telugu),
    /// else Latin when there are enough Latin letters, else nil.
    static func language(of text: String) -> MusicLanguage? {
        let counts = scriptCounts(text)
        if let top = counts.filter({ $0.key != .latin }).max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }) { return top.key }
        return (counts[.latin] ?? 0) >= 3 ? .latin : nil
    }

    /// The language the track's source states, or nil when it states none (or one this list does not have).
    static func stated(_ track: MusicTrack) -> MusicLanguage? {
        track.hints?.language.flatMap { MusicLanguage(stated: $0) }
    }

    /// A song's language: what its source states first, then the writing system of its text (see `MusicLanguage`).
    static func language(of track: MusicTrack) -> MusicLanguage? {
        if let s = stated(track) { return s }
        // The title and the album title only. The artist's name says where the artist is from, not what language this song is in (a Korean act releases English songs).
        let text = [track.title, track.album?.title ?? ""].joined(separator: " ")
        return language(of: text)
    }
}

/// What a person's own plays and likes say about the languages they listen to.
struct MusicLanguageProfile: Equatable, Sendable {
    var counts: [MusicLanguage: Int] = [:]
    var total = 0

    static func build(from tracks: [MusicTrack]) -> MusicLanguageProfile {
        var p = MusicLanguageProfile()
        for t in tracks {
            guard let l = MusicLanguageDetector.language(of: t) else { continue }
            p.counts[l, default: 0] += 1
            p.total += 1
        }
        return p
    }

    func share(_ language: MusicLanguage) -> Double { total > 0 ? Double(counts[language] ?? 0) / Double(total) : 0 }

    /// Non-Latin languages seen at least `minCount` times, most played first.
    func found(minCount: Int = 2) -> [MusicLanguage] {
        counts.filter { $0.key != .latin && $0.value >= minCount }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map(\.key)
    }

    /// The one non-Latin language that clearly leads: at least `minCount` songs and at least `minShare` of everything classified.
    func dominant(minShare: Double = 0.3, minCount: Int = 3) -> MusicLanguage? {
        guard let top = found(minCount: minCount).first, share(top) >= minShare else { return nil }
        return top
    }
}
