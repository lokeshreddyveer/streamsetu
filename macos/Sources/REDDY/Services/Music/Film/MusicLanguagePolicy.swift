import Foundation

/// Which languages a Music page asks the film and person sources for. Nothing here names a language: the list comes from the person's own
/// system languages and from what a film or person says about itself (its original language), so any language works the same way.
enum MusicLanguagePolicy {
    /// Two-letter codes in the person's order, each once ("te", "en").
    static func codes(preferred: [String] = Locale.preferredLanguages, extra: [String] = []) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in extra + preferred.compactMap({ Locale(identifier: $0).language.languageCode?.identifier }) {
            let c = raw.lowercased()
            if !c.isEmpty, seen.insert(c).inserted { out.append(c) }
        }
        return out
    }

    /// The `language` parameter for TMDB text: the person's first language as the system writes it ("te-IN"), else the neutral default.
    static func tmdbText(preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.first(where: { !$0.isEmpty }) ?? "en-US"
    }

    /// `include_image_language` / `include_video_language`: pictures with no printed text, then the film's own language, then the person's.
    static func tmdbMedia(original: String? = nil, preferred: [String] = Locale.preferredLanguages) -> String {
        (["null"] + codes(preferred: preferred, extra: original.map { [$0] } ?? [])).joined(separator: ",")
    }

    /// The label languages for a Wikidata query: the person's, then English as the universal last resort the label service falls back to.
    static func wikidataLabels(preferred: [String] = Locale.preferredLanguages, extra: [String] = []) -> String {
        var list = codes(preferred: preferred, extra: extra)
        if !list.contains("en") { list.append("en") }
        return list.joined(separator: ",")
    }
}
