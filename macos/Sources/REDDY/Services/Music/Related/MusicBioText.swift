import Foundation

enum MusicBioText {
    /// A source's artist biography cut to a short line for a small card: the first sentence, and when that is still long, cut at a word with an ellipsis (never mid-word).
    static func shortLine(_ bio: String, maxChars: Int = 110) -> String? {
        let t = bio.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var sentence = t
        if let r = t.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { sentence = String(t[..<r.upperBound]).trimmingCharacters(in: .whitespaces) }
        if sentence.count <= maxChars { return sentence }
        let cut = String(sentence.prefix(maxChars))
        let atWord = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
    }
}
