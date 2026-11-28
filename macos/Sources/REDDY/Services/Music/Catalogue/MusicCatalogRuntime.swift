import Foundation

/// The one place that connects the matcher to the rest of Music. Installed once by `MusicBuiltIns.register`; every entry point below is safe to call
/// from any thread and does nothing (returns its input) when the catalogue setting is off or Music is not installed.
final class MusicCatalogRuntime: @unchecked Sendable {
    static let shared = MusicCatalogRuntime()
    /// UserDefaults key of the Playback setting "Use catalogue sources to improve matching". On when absent.
    static let settingKey = "music.catalogue.enabled"
    /// The chart playability pipeline: one per app (see `MusicChartResolver`).
    let charts = MusicChartResolver()

    private let lock = NSLock()
    private var _matcher: MusicCatalogMatcher?
    private var _country: String?
    private var _store: MusicCanonicalStore = .shared
    private var _defaults: UserDefaults = .standard
    private var libraryCountry: (@Sendable () async -> String)?

    var isEnabled: Bool { lock.withLock { _defaults.object(forKey: Self.settingKey) as? Bool ?? true } && matcher != nil }
    var matcher: MusicCatalogMatcher? { lock.withLock { _matcher } }
    var store: MusicCanonicalStore { lock.withLock { _store } }
    /// The store country last read from the library settings; ITunesProvider reads it.
    var country: String? { lock.withLock { _country } }

    func setEnabled(_ on: Bool) { lock.withLock { _defaults.set(on, forKey: Self.settingKey) } }
    var settingIsOn: Bool { lock.withLock { _defaults.object(forKey: Self.settingKey) as? Bool ?? true } }

    /// Wires the matcher in. `country` reads the store country from the library settings (main actor).
    func configure(matcher: MusicCatalogMatcher, store: MusicCanonicalStore, defaults: UserDefaults, initialCountry: String?, country: (@Sendable () async -> String)?) {
        lock.withLock { _matcher = matcher; _store = store; _defaults = defaults; libraryCountry = country; _country = initialCountry }
    }

    /// Re-reads the store country from the library settings (called before a search, off the main thread).
    func refreshCountry() async {
        guard let f = lock.withLock({ libraryCountry }) else { return }
        let c = await f()
        lock.withLock { _country = c }
    }

    /// Test seam: install a matcher built by hand.
    func installForTesting(matcher: MusicCatalogMatcher?, store: MusicCanonicalStore, defaults: UserDefaults) {
        lock.withLock { _matcher = matcher; _store = store; _defaults = defaults }
    }

    /// The privacy wipe: forget every song match.
    func wipe() { store.clear(); MusicChartCache.shared.clear() }
}

// MARK: lyrics hook

/// Feeds the catalogue's canonical words into the lyrics questions as the first and best variants.
enum MusicCatalogLyricsHook {
    static func apply(_ variants: [MusicLyricsQueryVariant], request: MusicLyricsRequest, limit: Int) -> [MusicLyricsQueryVariant] {
        let rt = MusicCatalogRuntime.shared
        guard rt.isEnabled, !request.isLocal else { return variants }
        let cleaned = MusicLyricsQueryBuilder.cleanTitle(request.title)
        let title = cleaned.title.isEmpty ? request.title : cleaned.title
        guard let c = rt.store.lookup(title: title, artists: MusicLyricsQueryBuilder.cleanArtists(request.artists), videoID: request.videoID, isrc: request.isrc) else { return variants }
        return merge(canonical: c, variants: variants, limit: limit)
    }

    static func merge(canonical c: MusicCanonicalTrack, variants: [MusicLyricsQueryVariant], limit: Int) -> [MusicLyricsQueryVariant] {
        var out: [MusicLyricsQueryVariant] = []
        func add(_ v: MusicLyricsQueryVariant) {
            let k = MusicText.normalize(v.title + " " + v.artists)
            if !out.contains(where: { MusicText.normalize($0.title + " " + $0.artists) == k }) { out.append(v) }
        }
        let hint = c.film ?? c.album
        if !c.artists.isEmpty { add(MusicLyricsQueryVariant(title: c.title, artists: c.artistLine, album: c.album ?? hint, kind: .cleanWithArtist)) }
        add(MusicLyricsQueryVariant(title: c.title, artists: "", album: hint, kind: .cleanTitleOnly))
        for v in variants { add(v) }
        return Array(out.prefix(limit))
    }
}

// MARK: artwork hook

/// Swaps in the catalogue's cover when the playable copy's own picture is a video frame or small.
enum MusicCatalogArtwork {
    static func isVideoFrame(_ url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host?.lowercased() else { return false }
        return (host.hasSuffix("ytimg.com") || host.hasSuffix("youtube.com")) && (u.path.contains("/vi/") || u.path.contains("/vi_webp/"))
    }

    /// The address to show, given the thumbnails the track carries; nil keeps the usual choice.
    static func upgrade(_ thumbs: [MusicThumbnail], neededPixels: Int) -> String? {
        let rt = MusicCatalogRuntime.shared
        guard rt.isEnabled, !thumbs.isEmpty else { return nil }
        for t in thumbs { if let cover = rt.store.cover(forThumbnail: t.url) { return choose(own: thumbs, catalogueCover: cover, neededPixels: neededPixels) } }
        return nil
    }

    /// The catalogue cover when the song's own best picture is a video frame, narrower than needed, or has no stated size; else nil (keep own).
    static func choose(own thumbs: [MusicThumbnail], catalogueCover: String?, neededPixels: Int) -> String? {
        guard let cover = catalogueCover else { return nil }
        guard let widest = thumbs.max(by: { $0.width < $1.width }) else { return cover }
        if isVideoFrame(widest.url) || widest.width == 0 || widest.width < neededPixels { return cover }
        return nil
    }
}

/// The film a song came from, for the "From <film>" line and for grouping.
extension MusicCatalogNames {
    static func film(for track: MusicTrack) -> String? {
        let rt = MusicCatalogRuntime.shared
        guard rt.isEnabled else { return nil }
        return rt.store.canonical(for: track)?.film
    }
}

// MARK: canonical names for scrobble and stats

enum MusicCatalogNames {
    /// The catalogue's title and artists for a track, when known; scrobbles, stats and lyrics can use them instead of the video's wording.
    static func canonical(for track: MusicTrack) -> (title: String, artists: [String])? {
        let rt = MusicCatalogRuntime.shared
        guard rt.isEnabled, let c = rt.store.canonical(for: track), c.isMatched else { return nil }
        return (c.title, MusicCompilationArtist.meaningful(c.artists))
    }
}
