import Foundation

extension YouTubeMusicClient {
    /// The song credits panel for one video: the `next` reply (the same call a queue makes), then the credits page it points to, one request after the
    /// other. Empty when the song has no panel or either call fails. For a background lane, never for playback.
    func trackCredits(videoID: String) async -> [MusicCredit] {
        guard let reply = try? await next(videoID: videoID), let id = YouTubeMusicCreditMapper.creditsBrowseID(inNext: reply.root),
              let page = try? await browse(id, mode: .anonymous) else { return [] }
        return YouTubeMusicCreditMapper.parseCredits(page.root)
    }
}
