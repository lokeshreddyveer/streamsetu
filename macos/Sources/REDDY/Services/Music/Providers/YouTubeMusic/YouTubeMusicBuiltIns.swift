import Foundation

/// Registers the full YouTube Music provider. The older `YouTubeMusicProvider` (id "youtube-music") stays available as a fallback.
enum YouTubeMusicBuiltIns {
    @MainActor static func register(into registry: MusicRegistry, session: YouTubeMusicSession = GuestYouTubeMusicSession(),
                                    quality: @escaping @Sendable () -> MusicQuality = { .high }) {
        registry.register(YouTubeMusicFullProvider(session: session, quality: quality))
    }
}
