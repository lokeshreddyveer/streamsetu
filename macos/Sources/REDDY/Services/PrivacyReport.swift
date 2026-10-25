import Foundation

/// A plain list of what StreamSetu keeps on this device and what it can send out, with each item's current state.
/// It follows the privacy policy and is built from the live settings, so it shows what is true now and not a generic promise.
struct PrivacyReport: Equatable, Sendable {
    /// What the app can know about this device's current setup.
    struct State: Equatable, Sendable {
        var diagnosticsOn = true
        var hasTMDBKey = false
        var hasOpenSubtitles = false
        /// An online AI (not the on-device one) is set up for the assistant.
        var hasOnlineAI = false
        var hasTrakt = false
        var iCloudSync = false
        var lanSync = false
        var profileCount = 1
        var historyCount = 0
        var favoriteCount = 0
        var searchCount = 0
        var sessionCount = 0
        var playlistCount = 0
    }

    enum Status: Equatable, Sendable { case on, off, whenYouAsk }

    struct Item: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let status: Status
    }

    /// Kept on this device only.
    var stored: [Item] = []
    /// Contacts outside this device: who, what they get, and whether it happens now.
    var sentOut: [Item] = []

    static func make(_ s: State) -> PrivacyReport {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count) \(many)" }
        var r = PrivacyReport()
        r.stored = [
            Item(id: "history", title: "Watch history and resume points", detail: n(s.historyCount, "title", "titles") + ". Titles played with Watch Privately are never saved.", status: .on),
            Item(id: "fav", title: "Favourites and collections", detail: n(s.favoriteCount, "favourite", "favourites") + ".", status: .on),
            Item(id: "search", title: "Recent searches", detail: n(s.searchCount, "search", "searches") + ", the latest 30 at most.", status: .on),
            Item(id: "stats", title: "Viewing statistics", detail: n(s.sessionCount, "playback session", "playback sessions") + " behind the Statistics page.", status: .on),
            Item(id: "profiles", title: "Profiles", detail: n(s.profileCount, "profile", "profiles") + ". Each keeps its own history and favourites.", status: .on),
            Item(id: "logins", title: "Playlist logins", detail: "\(n(s.playlistCount, "playlist", "playlists")). Passwords stay in the system's secure storage.", status: .on)
        ]
        r.sentOut = [
            Item(id: "provider", title: "Your IPTV provider", detail: "Everything you play and browse goes to the provider you added. It sees what its own server serves, as with any player.", status: .on),
            Item(id: "diag", title: "StreamSetu playback log", detail: "After a stream fails for good: player used, timings, error codes and device model. Server names are masked. Never titles, logins or stream addresses. Deleted after 30 days.", status: s.diagnosticsOn ? .on : .off),
            Item(id: "tmdb", title: "The Movie Database (TMDB)", detail: "A title and year, to fetch artwork and details. Only with your own key.", status: s.hasTMDBKey ? .on : .off),
            Item(id: "subs", title: "OpenSubtitles", detail: "Title, year and language, and your own account to sign in. Only when you ask for subtitles.", status: s.hasOpenSubtitles ? .whenYouAsk : .off),
            Item(id: "ai", title: "An online AI (assistant)", detail: "Your messages and the conversation so far; with \"let the assistant see the screen\" on, also the screen you are on, the open title, your search text, what is playing (never while watching privately) and a few library counts. Only when you use the assistant, with your own key.", status: s.hasOnlineAI ? .whenYouAsk : .off),
            Item(id: "wiki", title: "Wikipedia (assistant lookups)", detail: "The film, series or person the assistant looks up. Only when an online AI is set up and you ask something that needs it.", status: s.hasOnlineAI ? .whenYouAsk : .off),
            Item(id: "trakt", title: "Trakt", detail: "When you start and stop watching a title, and your watchlist when you import it. Never for private watching. Only with your own Trakt app.", status: s.hasTrakt ? .on : .off),
            Item(id: "trailer", title: "YouTube and Apple trailers", detail: "Only when you open a trailer.", status: .whenYouAsk),
            Item(id: "podcast", title: "Apple podcast directory", detail: "The words you type, when you search for a podcast.", status: .whenYouAsk),
            Item(id: "icloud", title: "iCloud sync", detail: "Favourites, collections and resume points, in your own iCloud. Not visible to the developer.", status: s.iCloudSync ? .on : .off),
            Item(id: "lan", title: "Wi-Fi sync", detail: "Between your own devices on this network, encrypted and paired with a code. Nothing goes through the internet.", status: s.lanSync ? .on : .off)
        ]
        return r
    }

    /// The things this app does not do.
    static let neverDone = ["No account to create", "No advertising identifiers", "No analytics", "No selling or sharing of your data", "No automatic crash reporting"]
}
