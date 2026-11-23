import Foundation

/// What to offer when the search box is empty: moods and example searches. Tapping one fills the box; nothing is sent anywhere until the person searches.
struct SearchIdea: Identifiable, Hashable, Sendable {
    let label: String
    let query: String
    let symbol: String
    var id: String { query }
}

enum SearchIdeas {
    static let moods: [SearchIdea] = [
        .init(label: "Date night", query: "something for date night", symbol: "heart"),
        .init(label: "With the kids", query: "a movie with the kids", symbol: "figure.2.and.child.holdinghands"),
        .init(label: "Feel-good", query: "something feel-good and light", symbol: "sun.max"),
        .init(label: "Edge of my seat", query: "something gripping, edge of my seat", symbol: "bolt"),
        .init(label: "Mind-bending", query: "a mind-bending sci-fi thriller", symbol: "sparkles"),
        .init(label: "Make me laugh", query: "something to make me laugh", symbol: "face.smiling"),
        .init(label: "Short one", query: "something short before bed", symbol: "clock"),
        .init(label: "Binge", query: "a series to binge this weekend", symbol: "tv"),
        .init(label: "Hidden gem", query: "a hidden gem I have not watched", symbol: "diamond"),
        .init(label: "Award-winning", query: "award winning movies I have not watched", symbol: "star"),
    ]

    /// Example searches. The language in them is the person's own: the audio language chosen in Settings, else the device's language, so a Spanish
    /// or Korean library is never shown another region's example. `languages` (English names, most common first) may be passed by a caller that knows the library.
    static var examples: [SearchIdea] { examples(languages: LibraryLanguageHint.read()) }

    static func examples(languages: [String], audioSetting: String? = UserDefaults.standard.string(forKey: "settings.alang"), locale: Locale = .current) -> [SearchIdea] {
        let first = exampleLanguage(languages: languages, audioSetting: audioSetting, locale: locale)
        let second = languages.dropFirst().first(where: { $0.lowercased() != first.lowercased() }) ?? first
        let lang = first.lowercased(), lang2 = second.lowercased()
        return [
            .init(label: "top rated \(lang) movies", query: "top rated \(lang) movies", symbol: "text.magnifyingglass"),
            .init(label: "\(lang2) movies 2020s, unwatched", query: "\(lang2) movies 2020s unwatched", symbol: "text.magnifyingglass"),
            .init(label: "newest series", query: "newest series", symbol: "text.magnifyingglass"),
            .init(label: "an actor's films: a name, then “movies”", query: "tom hanks movies", symbol: "person"),
            .init(label: "go to live tv", query: "go to live tv", symbol: "arrow.right"),
            .init(label: "resume", query: "resume", symbol: "play"),
        ]
    }

    /// The English name of the language an example should use: a library language, else the Settings audio language, else the device's, else "english".
    static func exampleLanguage(languages: [String], audioSetting: String?, locale: Locale) -> String {
        if let l = languages.first(where: { !$0.isEmpty }) { return l }
        if let a = audioSetting, let n = OtherLanguages.preferredName(a) { return n }
        if let code = locale.language.languageCode?.identifier, let n = OtherLanguages.preferredName(code) { return n }
        return "English"
    }
}
