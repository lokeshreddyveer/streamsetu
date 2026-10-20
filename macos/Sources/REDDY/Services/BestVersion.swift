import Foundation

/// Which copy of a title is the best one to start with, judged only by the words the playlist put in its name and its folder ("[4K HDR]", "FHD", "HDCAM"). A recording made
/// in a cinema ranks below everything else, and a copy that says nothing about its quality ranks between SD and 720p. Nothing is guessed from the stream itself.
enum BestVersion {
    private static func has(_ pattern: String, in text: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }

    static func score(_ texts: [String?]) -> Int {
        let badges = QualityBadges.from(texts, limit: 9)
        let text = texts.compactMap { $0 }.joined(separator: " ")
        var s: Int
        if badges.contains("4K") { s = 400 } else if badges.contains("1080p") { s = 300 } else if badges.contains("720p") { s = 200 }
        else if has(#"\b(sd|480p|360p|576p)\b"#, in: text) { s = 50 } else { s = 100 }
        if badges.contains("Dolby Vision") { s += 12 }
        if badges.contains("HDR10+") { s += 10 } else if badges.contains("HDR") { s += 8 }
        if badges.contains("Atmos") { s += 6 }
        if badges.contains("7.1") { s += 3 } else if badges.contains("5.1") { s += 2 }
        if has(#"\b(cam|hdcam|hd-cam|camrip|ts|hdts|telesync|tc|telecine|scr|screener|dvdscr)\b"#, in: text) { s -= 400 }
        return s
    }

    /// The copies, best first. Copies that score the same keep the order they came in, so the one the person opened stays first when nothing is better.
    static func order<T>(_ copies: [T], words: (T) -> [String?]) -> [T] {
        copies.enumerated().sorted { a, b in
            let sa = score(words(a.element)), sb = score(words(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }
}
