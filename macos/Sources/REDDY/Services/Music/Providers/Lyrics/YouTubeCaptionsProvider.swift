import Foundation

/// The YouTube client another part of the app provides, for timed captions. Until one is connected the captions source is unavailable.
protocol MusicYouTubeCaptionsSource: Sendable {
    /// Timed caption lines for the video. Empty means the video has none.
    func captions(videoID: String) async throws -> [MusicYouTubeTimedLine]
}

final class MusicYouTubeCaptionsLink: @unchecked Sendable {
    private let lock = NSLock()
    private var _source: (any MusicYouTubeCaptionsSource)?
    var source: (any MusicYouTubeCaptionsSource)? {
        get { lock.lock(); defer { lock.unlock() }; return _source }
        set { lock.lock(); _source = newValue; lock.unlock() }
    }
    init(source: (any MusicYouTubeCaptionsSource)? = nil) { _source = source }
}

/// Captions of the exact playing video, as line-timed lyrics. Often the only timed text for songs no database has.
struct MusicYouTubeCaptionsProvider: MusicLyricsRequestProvider {
    let link: MusicYouTubeCaptionsLink
    init(link: MusicYouTubeCaptionsLink = MusicYouTubeCaptionsLink()) { self.link = link }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.ytCaptions, name: "YouTube captions", summary: MusicLyricsSources.about[MusicLyricsSources.ytCaptions] ?? "",
                          privacyNote: "The video id of the song being played is sent to YouTube to read its captions.")
    }
    var capabilities: MusicCapabilities { [.lyrics] }
    var isAvailable: Bool { link.source != nil }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard let source = link.source else { throw MusicError.unsupported("YouTube captions are not connected") }
        guard !request.isLocal, !request.searched, let id = request.videoID, MusicLyricsText.plausibleVideoID(id) else { return nil }
        let lines = try await source.captions(videoID: id)
        guard !lines.isEmpty else { return nil }
        let out = lines.map { MusicLyricLine(timeMs: $0.startMs, text: $0.text) }
        return MusicLyricsNormalizer.normalize(MusicLyrics(synced: out, sourceName: MusicLyricsSources.name(MusicLyricsSources.ytCaptions), providerID: MusicLyricsSources.ytCaptions))
    }

    // MARK: readers for the client that makes the calls

    /// `transcriptCueRenderer` entries `{startOffsetMs, cue}`. The cue text is trimmed of spaces, newlines and the note glyph; empty ones
    /// are skipped; the result is sorted. Nested `text`/`simpleText` objects are read too.
    static func transcriptLines(in json: Any) -> [MusicYouTubeTimedLine] {
        var out: [MusicYouTubeTimedLine] = []
        collect(json, into: &out, depth: 0)
        return out.sorted { $0.startMs < $1.startMs }
    }

    private static func collect(_ any: Any, into out: inout [MusicYouTubeTimedLine], depth: Int) {
        guard depth < 24 else { return }
        if let d = any as? [String: Any] {
            if let r = d["transcriptCueRenderer"] as? [String: Any], let ms = MusicLyricsIO.int64(r["startOffsetMs"]) {
                let text = plainText(r["cue"]).trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t♪"))
                if !text.isEmpty { out.append(MusicYouTubeTimedLine(text: text, startMs: ms)) }
                return
            }
            for v in d.values { collect(v, into: &out, depth: depth + 1) }
        } else if let a = any as? [Any] { for v in a { collect(v, into: &out, depth: depth + 1) } }
    }

    static func plainText(_ any: Any?) -> String {
        if let s = any as? String { return s }
        guard let d = any as? [String: Any] else { return "" }
        if let s = d["simpleText"] as? String { return s }
        if let s = d["text"] as? String { return s }
        if let runs = d["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        if let inner = d["text"] { return plainText(inner) }
        return ""
    }

    /// The caption file's `json3` shape: `events[{tStartMs, segs[{utf8}]}]`.
    static func json3Lines(_ obj: Any) -> [MusicYouTubeTimedLine] {
        guard let events = (obj as? [String: Any])?["events"] as? [[String: Any]] else { return [] }
        let lines = events.compactMap { e -> MusicYouTubeTimedLine? in
            guard let ms = MusicLyricsIO.int64(e["tStartMs"]), let segs = e["segs"] as? [[String: Any]] else { return nil }
            let text = segs.compactMap { $0["utf8"] as? String }.joined().trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t♪"))
            return text.isEmpty ? nil : MusicYouTubeTimedLine(text: text, startMs: ms)
        }
        return lines.sorted { $0.startMs < $1.startMs }
    }
}
