import Foundation

/// Registers every built-in provider. Registering only makes a provider known; which ones start switched on is decided by the first-run setup (all but Local files), then by the person.
enum MusicBuiltIns {
    @MainActor static func register(into registry: MusicRegistry, library: MusicLibrary? = nil) {
        MusicCatalogRuntime.shared.install(registry: registry, library: library)
        registry.register(AudiusProvider())
        registry.register(SoundCloudProvider())
        registry.register(JioSaavnProvider())
        registry.register(ITunesProvider(country: { MusicCatalogRuntime.shared.country }))
        registry.register(SpotifyProvider())
        registry.register(YouTubeMusicProvider())
        YouTubeMusicBuiltIns.register(into: registry)
        registry.register(PipedProvider())
        registry.register(InvidiousProvider())
        registry.register(LocalFilesProvider())
        MusicDiscoveryBuiltIns.register(into: registry)
        MusicLyricsBuiltIns.register(into: registry)
        registry.register(ListenBrainzProvider())
        registry.register(LastFMProvider())
        // Known but off: it needs a server address and login, so it is not part of the default set and makes no network call until one is added.
        registry.register(SubsonicProvider())
    }
}
