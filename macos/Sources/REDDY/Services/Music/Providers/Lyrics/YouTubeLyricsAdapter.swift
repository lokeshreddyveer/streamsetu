import Foundation

/// Connects the full YouTube Music provider to the two YouTube lyrics sources (the Lyrics tab and the captions) through its own client,
/// so they share its locale, retries and identity. Wire it once with `MusicLyricsBuiltIns.connectYouTube(_:)`.
struct YouTubeMusicLyricsAdapter: MusicYouTubeLyricsSource, MusicYouTubeCaptionsSource {
    let provider: YouTubeMusicFullProvider

    func facts(videoID: String) async throws -> MusicYouTubeLyricsFacts {
        let page = YTMPageParser.parseNext(try await provider.client.next(videoID: videoID).root)
        let own = page.tracks.first { $0.id == videoID }
        return MusicYouTubeLyricsFacts(durationSeconds: own.flatMap { $0.durationMs > 0 ? Double($0.durationMs) / 1000 : nil },
                                       album: own?.album?.title, lyricsBrowseID: page.lyricsBrowseID)
    }

    func timedLines(browseID: String) async throws -> [MusicYouTubeTimedLine] {
        let r = try await provider.client.browse(browseID, mode: .anonymous, client: .iosMusic)
        return YTMPageParser.parseTimedLyrics(r.root).map { MusicYouTubeTimedLine(text: $0.text, startMs: $0.timeMs) }
    }

    func plainLyrics(browseID: String) async throws -> MusicYouTubePlainLyrics? {
        let r = try await provider.client.browse(browseID)
        return YTMPageParser.parsePlainLyrics(r.root).map { MusicYouTubePlainLyrics(text: $0.text, footer: $0.source) }
    }

    /// Captions: the transcript endpoint first; a video whose transcript call fails falls back to its caption track file.
    func captions(videoID: String) async throws -> [MusicYouTubeTimedLine] {
        if let r = try? await provider.client.post("get_transcript", body: ["params": Self.transcriptParams(videoID: videoID)], client: .web, mode: .anonymous) {
            let lines = MusicYouTubeCaptionsProvider.transcriptLines(in: r.root)
            if !lines.isEmpty { return lines }
        }
        return []
    }

    /// The request parameter the transcript endpoint wants: a one-field message holding the video id, URL-safe base64.
    static func transcriptParams(videoID: String) -> String {
        var bytes: [UInt8] = [0x0A, UInt8(videoID.utf8.count)]
        bytes += Array(videoID.utf8)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
