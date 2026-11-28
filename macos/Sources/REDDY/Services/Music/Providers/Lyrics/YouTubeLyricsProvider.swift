import Foundation

/// What the walk's preface learns from YouTube Music's "next" call for a video id.
struct MusicYouTubeLyricsFacts: Sendable, Hashable {
    var durationSeconds: Double?
    var album: String?
    /// The `browseEndpoint` whose page type is the track-lyrics tab; nil when YouTube has no lyrics tab for the song.
    var lyricsBrowseID: String?
}

struct MusicYouTubeTimedLine: Sendable, Hashable { var text: String; var startMs: Int64 }
struct MusicYouTubePlainLyrics: Sendable, Hashable { var text: String; var footer: String? }

/// The YouTube Music client another part of the app provides. Until one is connected the YouTube lyrics source reports unavailable.
protocol MusicYouTubeLyricsSource: Sendable {
    /// The "next" call for the video id. Throwing means the call failed (the source then reports an error, not "no lyrics").
    func facts(videoID: String) async throws -> MusicYouTubeLyricsFacts
    /// `browse` as the mobile IOS_MUSIC client; the response must be handed to `MusicYouTubeLyricsProvider.timedLines(in:)`.
    func timedLines(browseID: String) async throws -> [MusicYouTubeTimedLine]
    /// `browse` as the WEB_REMIX client for the plain description shelf, parsed with `MusicYouTubeLyricsProvider.plainLyrics(in:)`.
    func plainLyrics(browseID: String) async throws -> MusicYouTubePlainLyrics?
}

/// Holds the source so wiring can connect it after the provider is registered.
final class MusicYouTubeLyricsLink: @unchecked Sendable {
    private let lock = NSLock()
    private var _source: (any MusicYouTubeLyricsSource)?
    var source: (any MusicYouTubeLyricsSource)? {
        get { lock.lock(); defer { lock.unlock() }; return _source }
        set { lock.lock(); _source = newValue; lock.unlock() }
    }
    init(source: (any MusicYouTubeLyricsSource)? = nil) { _source = source }
}

struct MusicYouTubeLyricsProvider: MusicLyricsRequestProvider {
    let link: MusicYouTubeLyricsLink
    init(link: MusicYouTubeLyricsLink = MusicYouTubeLyricsLink()) { self.link = link }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.youtube, name: "YouTube Music", summary: MusicLyricsSources.about[MusicLyricsSources.youtube] ?? "",
                          privacyNote: "The video id of the song being played is sent to YouTube Music to look up its lyrics.")
    }
    var capabilities: MusicCapabilities { [.lyrics] }
    var isAvailable: Bool { link.source != nil }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard let source = link.source else { throw MusicError.unsupported("YouTube lyrics are not connected") }
        if request.factsFailed { throw MusicError.network("YouTube did not answer") }
        guard let browse = request.youTubeBrowseID, !browse.isEmpty else { return nil }
        let name = MusicLyricsSources.name(MusicLyricsSources.youtube)
        if let timed = try? await source.timedLines(browseID: browse), !timed.isEmpty {
            let lines = timed.map { MusicLyricLine(timeMs: $0.startMs, text: $0.text) }
            return MusicLyricsNormalizer.normalize(MusicLyrics(synced: lines, sourceName: name, providerID: MusicLyricsSources.youtube))
        }
        guard let plain = try await source.plainLyrics(browseID: browse) else { return nil }
        var l = MusicLyrics(plain: plain.text, sourceName: name, providerID: MusicLyricsSources.youtube)
        if let f = plain.footer?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { l.sourceName = f }
        return MusicLyricsNormalizer.normalize(l)
    }

    // MARK: response readers for the client that makes the calls

    /// The first non-empty `timedLyricsData` array anywhere in the response; entries without a cue range are skipped.
    static func timedLines(in json: Any) -> [MusicYouTubeTimedLine] {
        guard let arr = firstArray(named: "timedLyricsData", in: json) else { return [] }
        return arr.compactMap { e in
            guard let text = e["lyricLine"] as? String, let cue = e["cueRange"] as? [String: Any],
                  let ms = MusicLyricsIO.int64(cue["startTimeMilliseconds"]) else { return nil }
            return MusicYouTubeTimedLine(text: text, startMs: ms)
        }
    }

    /// The description shelf's text and its footer (for example "Source: Musixmatch").
    static func plainLyrics(in json: Any) -> MusicYouTubePlainLyrics? {
        guard let shelf = firstObject(named: "musicDescriptionShelfRenderer", in: json) else { return nil }
        func runs(_ k: String) -> String? {
            guard let r = ((shelf[k] as? [String: Any])?["runs"]) as? [[String: Any]] else { return nil }
            let t = r.compactMap { $0["text"] as? String }.joined()
            return t.isEmpty ? nil : t
        }
        guard let text = runs("description"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MusicYouTubePlainLyrics(text: text, footer: runs("footer"))
    }

    /// The lyrics tab's browse id inside a "next" response.
    static func lyricsBrowseID(in json: Any) -> String? {
        if let d = json as? [String: Any] {
            if let be = d["browseEndpoint"] as? [String: Any], let id = be["browseId"] as? String,
               let cfg = (be["browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any],
               (cfg["pageType"] as? String) == "MUSIC_PAGE_TYPE_TRACK_LYRICS" { return id }
            for v in d.values { if let r = lyricsBrowseID(in: v) { return r } }
        } else if let a = json as? [Any] {
            for v in a { if let r = lyricsBrowseID(in: v) { return r } }
        }
        return nil
    }

    private static func firstArray(named key: String, in json: Any) -> [[String: Any]]? {
        if let d = json as? [String: Any] {
            if let a = d[key] as? [[String: Any]], !a.isEmpty { return a }
            for v in d.values { if let r = firstArray(named: key, in: v) { return r } }
        } else if let a = json as? [Any] {
            for v in a { if let r = firstArray(named: key, in: v) { return r } }
        }
        return nil
    }

    private static func firstObject(named key: String, in json: Any) -> [String: Any]? {
        if let d = json as? [String: Any] {
            if let o = d[key] as? [String: Any] { return o }
            for v in d.values { if let r = firstObject(named: key, in: v) { return r } }
        } else if let a = json as? [Any] {
            for v in a { if let r = firstObject(named: key, in: v) { return r } }
        }
        return nil
    }
}
