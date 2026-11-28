import Foundation

/// Registers the lyrics sources. Registering only makes a source known; every one starts switched on in the order list (an owner decision),
/// and the consent screen is where the person turns them off.
enum MusicLyricsBuiltIns {
    /// Where the YouTube Music client plugs in: set `youTubeLink.source` once it exists and the YouTube lyrics source becomes available.
    static let youTubeLink = MusicYouTubeLyricsLink()
    /// The same for the captions source.
    static let captionsLink = MusicYouTubeCaptionsLink()

    /// Connects both YouTube sources to the full YouTube Music provider's client.
    static func connectYouTube(_ provider: YouTubeMusicFullProvider) {
        let adapter = YouTubeMusicLyricsAdapter(provider: provider)
        youTubeLink.source = adapter
        captionsLink.source = adapter
    }

    /// The HTTP helper the lyrics sources share: the normal one, watched for blocked or failing replies (see `MusicLyricsProbe`).
    static func watchedHTTP() -> MusicHTTP {
        var h = MusicHTTP()
        h.transport = MusicLyricsRecordingTransport(inner: h.transport)
        return h
    }

    @MainActor static func register(into registry: MusicRegistry, http: MusicHTTP = MusicLyricsBuiltIns.watchedHTTP()) {
        registry.register(CommunityLyricsProvider(http: http))
        registry.register(LrcRedProvider(http: http))
        registry.register(BiniLyricsProvider(http: http))
        registry.register(BoiduProvider(http: http))
        registry.register(PortatoProvider(http: http))
        registry.register(PaxSenixProvider(http: http))
        registry.register(UnisonProvider(http: http))
        registry.register(LyricsPlusProvider(http: http))
        registry.register(SimpMusicProvider(http: http))
        registry.register(LRCLibProvider(http: http))
        registry.register(JioSaavnLyricsProvider(http: http))
        registry.register(MusicYouTubeLyricsProvider(link: youTubeLink))
        registry.register(MusicYouTubeCaptionsProvider(link: captionsLink))
        registry.register(NeteaseProvider(http: http))
        registry.register(QQMusicProvider(http: http))
        registry.register(KugouProvider(http: http))
        registry.register(MegalobizProvider(http: http))
        registry.register(MusixmatchProvider(http: http))
        registry.register(GeniusProvider(http: http))
        registry.register(LocalLyricsProvider())
    }
}
