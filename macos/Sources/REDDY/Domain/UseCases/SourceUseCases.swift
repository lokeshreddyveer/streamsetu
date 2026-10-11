import Foundation

/// Add a source: validate and store credentials safely, then start the first sync.
struct AddSourceUseCase: Sendable {
    let sources: SourceManager
    let sync: CatalogSyncService

    func xtream(name: String, server: String, username: String, password: String) async throws -> PlaylistSource {
        let s = try await sources.addXtream(name: name, server: server, username: username, password: password)
        await sync.start(sourceID: s.id)
        return s
    }
    func mediaServer(_ type: SourceType, name: String, server: String, username: String, password: String) async throws -> PlaylistSource {
        let s = try await sources.addMediaServer(type, name: name, server: server, username: username, password: password)
        await sync.start(sourceID: s.id)
        return s
    }
    func plex(name: String, server: String, token: String) async throws -> PlaylistSource {
        let s = try await sources.addPlex(name: name, server: server, token: token)
        await sync.start(sourceID: s.id)
        return s
    }
    func stalker(name: String, portal: String, mac: String) async throws -> PlaylistSource {
        let s = try await sources.addStalker(name: name, portal: portal, mac: mac)
        await sync.start(sourceID: s.id)
        return s
    }
    func hdhomerun(name: String, host: String) async throws -> PlaylistSource {
        let s = try sources.addHDHomeRun(name: name, host: host)
        await sync.start(sourceID: s.id)
        return s
    }
    func tvheadend(name: String, server: String, username: String, password: String) async throws -> PlaylistSource {
        let s = try sources.addTVHeadend(name: name, server: server, username: username, password: password)
        await sync.start(sourceID: s.id)
        return s
    }
    func m3u(name: String, url: String) async throws -> PlaylistSource {
        let s = try sources.addM3U(name: name, url: url)
        await sync.start(sourceID: s.id)
        return s
    }
    func m3uFile(name: String, file: URL) async throws -> PlaylistSource {
        let s = try sources.addM3UFile(name: name, fileURL: file)
        await sync.start(sourceID: s.id)
        return s
    }
}

struct RefreshSourceUseCase: Sendable {
    let sync: CatalogSyncService
    func callAsFunction(_ id: UUID, forceGuide: Bool = false) async { await sync.start(sourceID: id, forceGuide: forceGuide) }
}
