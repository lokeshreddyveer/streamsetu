#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Picks a fitting SF Symbol for a folder from its name, so the sidebar says what each group is at a glance. Each rule lists
/// symbols in order of preference; the first one this macOS has is used, and anything unrecognised gets a plain folder.
enum FolderIcons {
    private static let rules: [(words: [String], symbols: [String])] = [
        (["news", "headline", "journal"], ["newspaper", "newspaper.fill"]),
        (["cricket", "ipl"], ["figure.cricket", "sportscourt"]),
        (["football", "soccer", "premier league", "laliga", "bundesliga", "uefa", "fifa"], ["soccerball", "sportscourt"]),
        (["basketball", "nba"], ["basketball", "sportscourt"]),
        (["tennis"], ["tennisball", "sportscourt"]),
        (["golf"], ["figure.golf", "sportscourt"]),
        (["wrestling", "wwe", "ufc", "boxing", "mma", "fight"], ["figure.boxing", "figure.martial.arts"]),
        (["racing", "formula", "f1", "motorsport", "motogp"], ["flag.checkered", "car.fill"]),
        (["sport", "espn", "bein", "sky sports"], ["sportscourt", "trophy"]),
        (["kids", "children", "cartoon", "junior", "disney", "nick"], ["teddybear.fill", "figure.and.child.holdinghands", "face.smiling"]),
        (["anime", "manga"], ["sparkles"]),
        (["animation", "animated"], ["paintpalette", "sparkles"]),
        (["music", "mtv", "vevo", "hits", "radio fm", "songs"], ["music.note", "music.quarternote.3"]),
        (["radio"], ["dot.radiowaves.left.and.right", "radio"]),
        (["documentary", "discovery", "nature", "history", "geographic", "science"], ["globe.europe.africa", "binoculars"]),
        (["weather"], ["cloud.sun", "cloud.sun.fill"]),
        (["shopping", "shop", "qvc"], ["bag", "cart"]),
        (["religio", "islam", "christian", "gospel", "devotional", "church", "quran", "bhakti"], ["building.columns", "hands.sparkles"]),
        (["horror", "scary"], ["moon.stars", "theatermasks"]),
        (["comedy", "funny", "sitcom"], ["face.smiling", "theatermasks"]),
        (["action", "adventure"], ["bolt", "bolt.fill"]),
        (["romance", "romantic", "love"], ["heart", "heart.fill"]),
        (["thriller", "crime", "mystery", "detective"], ["eye", "magnifyingglass"]),
        (["sci-fi", "scifi", "science fiction", "fantasy"], ["sparkles", "wand.and.stars"]),
        (["drama", "entertainment", "general", "variety"], ["theatermasks", "tv"]),
        (["movie", "film", "cinema", "hollywood", "bollywood", "tollywood", "kollywood"], ["film", "film.stack"]),
        (["series", "tv show", "shows", "episodes", "season"], ["rectangle.stack", "play.rectangle.on.rectangle"]),
        (["netflix", "prime", "hbo", "hulu", "apple tv", "paramount", "peacock", "hotstar", "zee5", "sony liv", "streaming"], ["play.rectangle", "play.rectangle.fill"]),
        (["4k", "uhd", "2160"], ["4k.tv", "tv"]),
        (["premium", "vip", "gold", "exclusive"], ["crown", "star.fill"]),
        (["24/7", "24x7", "always"], ["clock.arrow.circlepath", "clock"]),
        (["live", "events", "ppv", "pay per view"], ["dot.radiowaves.left.and.right", "antenna.radiowaves.left.and.right"]),
        (["adult", "xxx", "18+"], ["lock"]),
        (["india", "indian", "hindi", "telugu", "tamil", "malayalam", "kannada", "bengali", "punjabi", "marathi", "pakistan", "bangla", "asia", "arabic", "arab", "turk", "korea", "japan", "china", "thai"], ["globe.asia.australia", "globe"]),
        (["uk", "britain", "british", "europe", "france", "french", "german", "italy", "italian", "spain", "spanish", "portugal", "dutch", "nordic"], ["globe.europe.africa", "globe"]),
        (["usa", "us ", "united states", "america", "canada", "latin", "brazil", "mexico"], ["globe.americas", "globe"]),
        (["favorite", "favourite", "my list"], ["heart", "star"]),
        (["recent", "new", "latest"], ["clock", "sparkles"]),
    ]

    private static func exists(_ symbol: String) -> Bool {
        #if canImport(AppKit)
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        #else
        UIImage(systemName: symbol) != nil
        #endif
    }

    /// Words are matched as whole words (or word starts), so "Sports" matches "sport" but "Newsroom" doesn't match "us".
    static func symbol(for name: String) -> String {
        let lower = " " + name.lowercased().map { $0.isLetter || $0.isNumber || "+/".contains($0) ? String($0) : " " }.joined() + " "
        for rule in rules {
            for w in rule.words where lower.contains(" " + w) && (w.count > 3 || lower.contains(" " + w + " ") || lower.contains(" " + w + "s ")) {
                if let s = rule.symbols.first(where: exists) { return s }
            }
        }
        return "folder"
    }
}
