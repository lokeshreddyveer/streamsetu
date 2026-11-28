import Foundation

/// Opening a page also warms the pages it links to, in the background, so tapping one finds it ready: the people credited on an album and the film, the
/// albums on a person's page. Warming is deliberately CHEAP: for a linked album it saves the first page of its songs on disk (so the album opens
/// instantly), and nothing else. It does NOT start the full filmography and discography fetch of a person or film: that is about a dozen requests
/// on shared, rate-limited sources, and doing it for pages nobody opens wastes the requests the page in front of the person needs. That heavier pass
/// runs when the page is really opened, and its answers are kept for two weeks, so the next page that shares the artist starts from them.
///
/// Bounded: at most `perPage` albums per page opened, one saved copy per album per ten minutes, nothing while Music is gated (Kids profile, app lock) or
/// while the Mac is in Low Power Mode.
@MainActor
final class MusicEntityWarmer {
    static let shared = MusicEntityWarmer()
    static let perPage = 4
    static let freshFor: TimeInterval = 600

    private var warmedAt: [MusicEntityID: Date] = [:]

    func warm(_ ids: [MusicEntityID], hub: MusicHub) {
        guard !hub.gated, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        var started = 0
        var seen = Set<MusicEntityID>()
        for id in ids where id.kind == .album || id.kind == .release {
            guard seen.insert(id).inserted, started < Self.perPage else { continue }
            if let t = warmedAt[id], Date().timeIntervalSince(t) < Self.freshFor { continue }
            warmedAt[id] = Date()
            started += 1
            Task(priority: .utility) { await Self.saveSongs(of: id, hub: hub) }
        }
        if warmedAt.count > 400 { warmedAt = warmedAt.filter { Date().timeIntervalSince($0.value) < Self.freshFor } }
    }

    private var warmedAlbums: [String: Date] = [:]

    /// Albums that are only provider values (Home's shelves): the first page of their songs is saved on disk the same way.
    func warm(albums: [MusicAlbum], hub: MusicHub) {
        guard !hub.gated, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        var started = 0
        for a in albums {
            guard started < Self.perPage, let provider = hub.registry.metadataProvider(id: a.providerID) else { continue }
            if let t = warmedAlbums[a.uid], Date().timeIntervalSince(t) < Self.freshFor { continue }
            warmedAlbums[a.uid] = Date(); started += 1
            let id = a.id
            Task(priority: .utility) { _ = try? await MusicPageCache.shared.albumTracksFirstPage(provider: provider, id: id) }
        }
        if warmedAlbums.count > 400 { warmedAlbums = warmedAlbums.filter { Date().timeIntervalSince($0.value) < Self.freshFor } }
    }

    /// The first page of a linked album's songs, saved on disk (no page is drawn).
    private static func saveSongs(of id: MusicEntityID, hub: MusicHub) async {
        let reader = MusicSoundtrackReader(MusicEntityRuntime.shared.store.graph)
        let family = await reader.family(of: id)
        guard let ref = await MusicSoundtrackSongs.providerAlbum(reader, family: family, enabled: hub.registry.enabled), let provider = hub.registry.metadataProvider(id: ref.provider) else { return }
        _ = try? await MusicPageCache.shared.albumTracksFirstPage(provider: provider, id: ref.id)
    }

    /// The privacy wipe.
    func forget() { warmedAt = [:]; warmedAlbums = [:] }
}
