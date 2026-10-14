import Foundation

/// What a `streamsetu://` link or a dropped item asks for. Links can come from a web page, a shortcut or another app, so they are
/// parsed strictly, can only do the things listed here, and never add a playlist by themselves: "add" only fills in the form.
enum DeepLink: Equatable {
    case addPlaylist(address: String, name: String?)
    case playChannel(name: String)
    case playMovie(title: String)
    case findSeries(title: String)
    case openTab(AppTab)
    case search(String)
    case sleep(minutes: Int)
    case remote(RemoteCommand)

    enum RemoteCommand: String, Equatable { case pause, resume, stop, next, previous, last }

    static let scheme = "streamsetu"

    /// streamsetu://add?url=…&name=…   play?channel=…   watch?movie=…   watch?series=…   open?tab=live   search?q=…   sleep?minutes=45   pause | resume | stop | next | previous | last
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // streamsetu://play?x=1 puts "play" in the host; streamsetu:///play does in the path
        let action = (comps?.host?.isEmpty == false ? comps?.host : comps?.path.split(separator: "/").first.map(String.init))?.lowercased() ?? ""
        func value(_ name: String) -> String? { comps?.queryItems?.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch action {
        case "add":
            guard let address = value("url"), let addr = validAddress(address) else { return nil }
            return .addPlaylist(address: addr, name: value("name").flatMap { $0.isEmpty ? nil : String($0.prefix(80)) })
        case "play":
            guard let name = value("channel"), !name.isEmpty, name.count <= 120 else { return nil }
            return .playChannel(name: name)
        case "watch":
            if let m = value("movie"), !m.isEmpty, m.count <= 120 { return .playMovie(title: m) }
            if let t = value("series"), !t.isEmpty, t.count <= 120 { return .findSeries(title: t) }
            return nil
        case "open":
            let tabs: [String: AppTab] = ["home": .home, "live": .liveTV, "livetv": .liveTV, "movies": .movies, "series": .series, "guide": .guide, "tvguide": .guide]
            guard let t = value("tab")?.lowercased().replacingOccurrences(of: " ", with: ""), let tab = tabs[t] else { return nil }
            return .openTab(tab)
        case "search":
            guard let q = value("q"), !q.isEmpty, q.count <= 200 else { return nil }
            return .search(q)
        case "sleep":
            guard let m = value("minutes").flatMap(Int.init), (1...600).contains(m) else { return nil }
            return .sleep(minutes: m)
        default:
            return RemoteCommand(rawValue: action).map { .remote($0) }
        }
    }

    /// An address worth putting in the Add Playlist form: http(s), with a host, and not absurdly long.
    static func validAddress(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 2000, let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host?.isEmpty == false else { return nil }
        return t
    }
}

/// What a dropped file or link means for the Add Playlist form.
enum PendingAdd: Equatable {
    case address(String, name: String?)
    case file(URL)

    static let playlistExtensions: Set<String> = ["m3u", "m3u8", "txt"]

    static func fromFile(_ url: URL) -> PendingAdd? { url.isFileURL && playlistExtensions.contains(url.pathExtension.lowercased()) ? .file(url) : nil }

    /// A link or pasted text that looks like a playlist address.
    static func fromText(_ text: String) -> PendingAdd? { DeepLink.validAddress(text).map { .address($0, name: nil) } }
}
