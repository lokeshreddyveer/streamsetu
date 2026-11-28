import Foundation
import CoreGraphics
import ImageIO

// Right-sized pictures. Each place a picture is drawn (a slot) asks for the size it draws, the address is rewritten to that size where the host
// supports it, a failed sized request falls back to the original address once, and a host's "missing" placeholder is treated as missing.
// Pure and shared with iOS. Research notes: ~/Documents/dev/music-artwork-everywhere.md (rows 15 to 20).

/// Where a picture is drawn, and how many pixels that place needs. A ladder lists sizes best first: now-playing tries 720, then 400, then 120.
enum MusicArtworkSlot: String, CaseIterable, Sendable {
    case avatar, row, backdrop, card, miniPlayer, nowPlaying, theaterWash, mediaSession

    func ladder(scale: CGFloat = 2) -> [Int] {
        switch self {
        case .avatar: [64]
        case .row: [120]
        case .backdrop: [96]
        case .card: scale >= 2 ? [400] : [200]
        case .miniPlayer: [480]
        case .nowPlaying: [720, 400, 120]
        case .theaterWash: [400]
        case .mediaSession: [512]
        }
    }

    /// The first size to ask for.
    func pixels(scale: CGFloat = 2) -> Int { ladder(scale: scale)[0] }

    /// The slot for a picture drawn `points` wide when no slot was named: avatars up to 32 pt, rows up to 64 pt, cards above.
    static func forPoints(_ points: CGFloat) -> MusicArtworkSlot {
        if points <= 32 { return .avatar }
        if points <= 64 { return .row }
        if points <= 240 { return .card }
        return .nowPlaying
    }

    /// Never decode more than about twice the pixels a slot draws.
    func decodeCap(scale: CGFloat = 2) -> Int { pixels(scale: scale) * 2 }
}

enum MusicArtworkURLSizing {
    /// A host's size hint inside an address, and how to change it.
    private struct Rule: Sendable {
        var pattern: String
        var size: @Sendable (_ requested: Int) -> Int
        var make: @Sendable (_ size: Int, _ match: NSTextCheckingResult, _ source: NSString) -> String
        /// Host suffixes the rule is limited to (nil: any host).
        var hosts: [String]? = nil
    }

    private static func snap(_ px: Int, _ steps: [Int]) -> Int { steps.first { $0 >= px } ?? steps.last ?? px }
    private static let wikimediaWidths = [20, 40, 60, 120, 250, 330, 500, 960, 1280, 1920, 3840]

    private static let rules: [Rule] = [
        // Google image hosts (YouTube Music covers and avatars): `=w544-h544-l90-rj` or `=s400`. Keep the other flags.
        Rule(pattern: "=(?:w\\d+-h\\d+|s\\d+)(?=(-[a-z0-9]+)*$)", size: { $0 },
             make: { px, _, _ in "=w\(px)-h\(px)" }, hosts: ["googleusercontent.com", "ggpht.com"]),
        // Apple: `.../600x600bb.jpg`
        Rule(pattern: "/\\d+x\\d+bb(?=\\.(?:jpg|png|webp)$)", size: { min(max($0, 60), 1000) }, make: { px, _, _ in "/\(px)x\(px)bb" }),
        // Deezer: `/500x500-000000-80-0-0.jpg` (56, 250, 500, 1000)
        Rule(pattern: "/\\d+x\\d+(?=-000000-80-0-0\\.jpg)", size: { snap($0, [56, 250, 500, 1000]) }, make: { px, _, _ in "/\(px)x\(px)" }),
        // JioSaavn: `-150x150.jpg` (50, 150, 500)
        Rule(pattern: "([-_])\\d+x\\d+(?=\\.(?:jpg|png)$)", size: { snap($0, [50, 150, 500]) }, make: { px, m, s in s.substring(with: m.range(at: 1)) + "\(px)x\(px)" }),
        // Cover Art Archive: `/front-500`
        Rule(pattern: "/front-\\d+$", size: { snap($0, [250, 500, 1200]) }, make: { px, _, _ in "/front-\(px)" }),
        // TMDB posters: `/t/p/w500/`
        Rule(pattern: "/t/p/w\\d+/", size: { snap($0, [92, 154, 185, 342, 500, 780]) }, make: { px, _, _ in "/t/p/w\(px)/" }),
        // Wikimedia thumbnails: `/500px-Name.jpg` (standard widths only; other widths are refused by the host)
        Rule(pattern: "/\\d+px-", size: { snap($0, wikimediaWidths) }, make: { px, _, _ in "/\(px)px-" }),
        // Wikimedia `Special:FilePath?width=`
        Rule(pattern: "([?&]width=)\\d+", size: { snap($0, wikimediaWidths) }, make: { px, m, s in s.substring(with: m.range(at: 1)) + String(px) }),
    ]

    private static func apply(_ url: String, _ rule: Rule, to px: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
        let ns = url as NSString
        guard let m = re.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.replacingCharacters(in: m.range, with: rule.make(rule.size(px), m, ns))
    }

    /// The address asking for `pixels` on the long side, or nil when the host's size cannot be changed or is already right. Plain `http` is upgraded.
    static func rewrite(_ url: String, to pixels: Int) -> String? {
        guard pixels > 0, let u = URL(string: url), let host = u.host?.lowercased() else { return nil }
        if host.hasSuffix("ytimg.com") { return videoThumbnail(url, pixels: pixels) }
        for r in rules where r.hosts.map({ list in list.contains { host.hasSuffix($0) } }) ?? true {
            if let out = apply(url, r, to: pixels) { return out == url ? nil : out }
        }
        return nil
    }

    /// `i.ytimg.com/vi/ID/NAME.jpg`: mqdefault 320, hqdefault 480, sddefault 640, maxresdefault 1280. The big file is asked for only by a slot of 720 or more
    /// (it does not exist for every video). `default` (120 x 90) is left alone.
    static func videoThumbnail(_ url: String, pixels: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: "/(default|mqdefault|hqdefault|sddefault|maxresdefault|hq720)\\.(jpg|webp)"),
              let m = re.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) else { return nil }
        let ns = url as NSString
        let current = ns.substring(with: m.range(at: 1)), ext = ns.substring(with: m.range(at: 2))
        if current == "default" { return nil }
        let name = pixels >= 720 ? "maxresdefault" : pixels > 480 ? "sddefault" : pixels > 320 ? "hqdefault" : "mqdefault"
        return name == current ? nil : ns.replacingCharacters(in: m.range, with: "/\(name).\(ext)")
    }

    /// Two-step retry: the sized address first, then the original once (skipped when sizing changed nothing, so a dead address is not fetched twice).
    static func attempts(for url: String, pixels: Int) -> [String] {
        var list: [String] = []
        if let sized = rewrite(url, to: pixels) { list.append(sized) }
        list.append(url)
        return list
    }

    /// A slot with a ladder (now-playing: 720, then 400, then 120) tries each size in turn, then the original once. Addresses are never repeated.
    static func attempts(for url: String, ladder: [Int]) -> [String] {
        var list: [String] = []
        for px in ladder { if let sized = rewrite(url, to: px), !list.contains(sized) { list.append(sized) } }
        if !list.contains(url) { list.append(url) }
        return list
    }

    /// The address with its size hint taken out: a cover at 120 px and at 400 px has one identity. Used to count DISTINCT covers.
    static func identity(_ url: String) -> String {
        var out = url
        if let q = out.firstIndex(of: "?"), !out.contains("width=") { out = String(out[..<q]) }
        if let eq = out.range(of: "=(?:w\\d+-h\\d+|s\\d+)(-[a-z0-9]+)*$", options: .regularExpression) { out.removeSubrange(eq) }
        for (pattern, template) in [("/\\d+x\\d+bb", "/SIZEbb"), ("/\\d+x\\d+(?=-000000-80-0-0)", "/SIZE"), ("[-_]\\d+x\\d+(?=\\.(?:jpg|png)$)", "-SIZE"), ("/front-\\d+$", "/front"),
                                    ("/t/p/w\\d+/", "/t/p/SIZE/"), ("/\\d+px-", "/SIZEpx-"), ("([?&]width=)\\d+", "$1SIZE")] {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        if out.hasPrefix("http://") { out = "https://" + out.dropFirst(7) }
        return out
    }

    /// The service's own 2x2 collage of a playlist's first songs has an address that carries only a bare size flag (`=s400`), where a chosen cover carries
    /// width and height flags. It is never used as a backdrop (it would only repeat the rows below it).
    static func isServiceCollage(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased(), host.hasSuffix("googleusercontent.com") || host.hasSuffix("ggpht.com") else { return false }
        return url.range(of: "=s\\d+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }
}

/// A host's "no such size" picture that loads without an error.
enum MusicArtworkPlaceholder {
    /// The video host answers a missing big thumbnail with a grey 120 x 90 picture (sometimes a 404). A real `default.jpg` is 120 x 90 too, so that name is exempt.
    /// The same check on the downloaded bytes, before decoding (a decode to a small bucket would hide the native size).
    static func isMissing(address: String, data: Data) -> Bool {
        guard address.contains("ytimg.com"), data.count < 20_000, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        return isMissing(address: address, width: w, height: h)
    }

    static func isMissing(address: String, width: Int, height: Int) -> Bool {
        guard width == 120, height == 90, let u = URL(string: address), let host = u.host?.lowercased(), host.hasSuffix("ytimg.com") else { return false }
        return !u.path.hasSuffix("/default.jpg") && !u.path.hasSuffix("/default.webp") && !["/1.jpg", "/2.jpg", "/3.jpg"].contains { u.path.hasSuffix($0) }
    }
}

/// Category tiles (mood, genre, language) are filled with the cover of the first thing in the category. They are fetched about six at a time and kept
/// seven days; an older cover is still shown while the new one is fetched (stale while revalidating), and a tile whose fetch fails stays a designed tile.
enum MusicTileCoverPolicy {
    static let ttl: TimeInterval = 7 * 86_400
    static let parallel = 6

    enum State: Equatable, Sendable { case fresh, stale, absent }

    /// `age` is how long ago the cover was learned; nil when there is none.
    static func state(age: TimeInterval?) -> State {
        guard let age else { return .absent }
        return age < ttl ? .fresh : .stale
    }
}
