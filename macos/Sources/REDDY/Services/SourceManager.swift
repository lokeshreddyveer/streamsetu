import Foundation

/// Creates, edits and removes sources. Logins go to the Keychain; the database only ever sees a reference
/// and a redacted display address.
final class SourceManager: @unchecked Sendable {
    let catalog: CatalogRepository
    let secure: SecureStorage
    let http: HTTPClient
    private let lock = NSLock()
    private var providers: [UUID: SourceProvider] = [:]

    let headersStore: SourceHeadersStore

    init(catalog: CatalogRepository, credentials: CredentialStore, http: HTTPClient, headers: SourceHeadersStore = SourceHeadersStore()) {
        self.headersStore = headers
        self.catalog = catalog
        self.secure = SecureStorage(store: credentials)
        self.http = http
    }

    // MARK: providers

    func makeProvider(for source: PlaylistSource) throws -> SourceProvider {
        if let cached = lock.withLock({ providers[source.id] }) { return cached }
        let provider: SourceProvider
        switch source.type {
        case .xtream:
            guard let creds = secure.credentials(for: source), let user = creds.username, let pass = creds.password
            else { throw SourceError.credentialsMissing }
            provider = XtreamProvider(source: source, account: XtreamAccount(base: source.baseURL, user: user, pass: pass, headers: headersStore.headers(for: source.id)), http: http)
        case .jellyfin, .emby:
            guard let creds = secure.credentials(for: source), let user = creds.username, let pass = creds.password
            else { throw SourceError.credentialsMissing }
            provider = MediaServerProvider(source: source, flavor: source.type == .emby ? .emby : .jellyfin, user: user, pass: pass,
                                           session: MediaSession(encoded: creds.url), http: http, credentials: secure.store, headers: headersStore.headers(for: source.id))
        case .plex:
            guard let token = secure.credentials(for: source)?.password, !token.isEmpty else { throw SourceError.credentialsMissing }
            provider = PlexProvider(source: source, token: token, http: http, headers: headersStore.headers(for: source.id))
        case .stalker:
            guard let mac = secure.credentials(for: source)?.username else { throw SourceError.credentialsMissing }
            provider = StalkerProvider(source: source, mac: mac, http: http, headers: headersStore.headers(for: source.id))
        case .m3uRemote:
            guard secure.credentials(for: source) != nil else { throw SourceError.credentialsMissing }
            provider = M3UProvider(source: source, http: http, credentials: secure.store, headers: withAuth(headersStore.headers(for: source.id), source: source))
        case .m3uLocal:
            let file = StorageService.importedPlaylists.appendingPathComponent(source.baseURL)
            guard FileManager.default.fileExists(atPath: file.path) else { throw SourceValidationError.fileMissing }
            provider = M3UProvider(source: source, http: http, credentials: secure.store, localFile: file)
        }
        lock.withLock { providers[source.id] = provider }
        return provider
    }

    /// `host` is the server a request is about to go to. The sign-in is only ever sent to the playlist's own server, never to another
    /// host the playlist points at (a CDN, another guide address). Leave it nil for the playlist's own download.
    func headers(for id: UUID, host: String? = nil) -> SourceHeaders {
        let h = headersStore.headers(for: id)
        guard let s = try? catalog.source(id: id) else { return h }
        return withAuth(h, source: s, host: host)
    }

    /// A playlist behind HTTP Basic or Bearer sign-in sends it with every request. The secret lives in the vault, never in preferences.
    private func withAuth(_ h: SourceHeaders, source: PlaylistSource, host: String? = nil) -> SourceHeaders {
        guard source.type == .m3uRemote, let c = secure.credentials(for: source), let value = Self.authorization(for: c) else { return h }
        if let host, host.lowercased() != c.url.flatMap({ URL(string: $0)?.host })?.lowercased() { return h }
        var out = h
        out.extra["Authorization"] = value
        return out
    }

    static func authorization(for c: Credentials) -> String? {
        if let u = c.username, !u.isEmpty, let p = c.password, !p.isEmpty { return "Basic " + Data("\(u):\(p)".utf8).base64EncodedString() }
        if let p = c.password, !p.isEmpty { return "Bearer " + p }
        return nil
    }

    /// What kind of sign-in a playlist link has saved (the secret itself is never handed back).
    func httpAuth(for id: UUID) -> (kind: HTTPAuthKind, username: String) {
        guard let s = try? catalog.source(id: id), let c = secure.credentials(for: s) else { return (.none, "") }
        if let u = c.username, !u.isEmpty, c.password?.isEmpty == false { return (.basic, u) }
        if c.password?.isEmpty == false { return (.bearer, "") }
        return (.none, "")
    }

    /// Saves (or clears) HTTP Basic or Bearer sign-in for a playlist link, next to its address in the vault.
    func setHTTPAuth(_ id: UUID, kind: HTTPAuthKind, username: String, secret: String) throws {
        guard let s = try catalog.source(id: id), s.type == .m3uRemote, let ref = s.credentialRef else { return }
        var c = secure.credentials(for: s) ?? Credentials()
        switch kind {
        case .none: c.username = nil; c.password = nil
        case .basic: guard !username.isEmpty, !secret.isEmpty else { throw SourceValidationError.empty }; c.username = username; c.password = secret
        case .bearer: guard !secret.isEmpty else { throw SourceValidationError.empty }; c.username = nil; c.password = secret
        }
        try secure.store.save(c, ref: ref)
        invalidateProvider(id)
    }

    /// Saves this playlist's User-Agent and extra headers and makes the next connection use them.
    func setHeaders(userAgent: String?, extraText: String, for id: UUID) {
        headersStore.set(userAgent: userAgent, extraText: extraText, for: id)
        invalidateProvider(id)
    }

    func invalidateProvider(_ id: UUID) { lock.withLock { providers[id] = nil } }

    // MARK: adding

    /// Verifies the login against the server first, so a typo is reported immediately instead of after a failed sync.
    func addXtream(name: String, server: String, username: String, password: String, verify: Bool = true) async throws -> PlaylistSource {
        let base = try SourceURLValidator.validateXtreamServer(server)
        guard !username.isEmpty, !password.isEmpty else { throw SourceValidationError.empty }
        let ref = try secure.save(Credentials(username: username, password: password))
        var source = PlaylistSource(name: name.nilIfEmpty ?? URL(string: base)?.host ?? "Xtream", type: .xtream, baseURL: base, credentialRef: ref)
        do {
            if verify {
                let provider = XtreamProvider(source: source, account: XtreamAccount(base: base, user: username, pass: password), http: http)
                source.capabilities = try await provider.validate()
            }
            try catalog.save(source: source)
            try catalog.saveCapabilities(source.capabilities, sourceID: source.id)
            return source
        } catch {
            secure.remove(ref: ref)
            throw error
        }
    }

    /// Jellyfin or Emby: the login is checked against the server first, so a typo is reported straight away.
    func addMediaServer(_ type: SourceType, name: String, server: String, username: String, password: String) async throws -> PlaylistSource {
        precondition(type == .jellyfin || type == .emby)
        let base = try SourceURLValidator.validateXtreamServer(server)
        guard !username.isEmpty, !password.isEmpty else { throw SourceValidationError.empty }
        let ref = try secure.save(Credentials(username: username, password: password))
        var source = PlaylistSource(name: name.nilIfEmpty ?? URL(string: base)?.host ?? type.title, type: type, baseURL: base, credentialRef: ref)
        do {
            let provider = MediaServerProvider(source: source, flavor: type == .emby ? .emby : .jellyfin, user: username, pass: password, session: nil, http: http, credentials: secure.store)
            source.capabilities = try await provider.validate()
            try catalog.save(source: source)
            try catalog.saveCapabilities(source.capabilities, sourceID: source.id)
            return source
        } catch {
            secure.remove(ref: ref)
            throw error
        }
    }

    /// A Stalker / Ministra / MAG portal. The box's MAC address is the login. The portal is asked once to make sure the box is accepted.
    func addStalker(name: String, portal: String, mac: String) async throws -> PlaylistSource {
        let base = try SourceURLValidator.validateXtreamServer(portal)
        guard let normalized = StalkerMapper.normalizedMAC(mac) else { throw SourceValidationError.invalid }
        let ref = try secure.save(Credentials(username: normalized, password: nil))
        var source = PlaylistSource(name: name.nilIfEmpty ?? URL(string: base)?.host ?? "Portal", type: .stalker, baseURL: base, credentialRef: ref)
        do {
            source.capabilities = try await StalkerProvider(source: source, mac: normalized, http: http).validate()
            try catalog.save(source: source)
            try catalog.saveCapabilities(source.capabilities, sourceID: source.id)
            return source
        } catch {
            secure.remove(ref: ref)
            throw error
        }
    }

    /// Plex: the server's address and an access token (the account's X-Plex-Token).
    func addPlex(name: String, server: String, token: String) async throws -> PlaylistSource {
        let base = try SourceURLValidator.validateXtreamServer(server)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw SourceValidationError.empty }
        let ref = try secure.save(Credentials(username: nil, password: t))
        var source = PlaylistSource(name: name.nilIfEmpty ?? URL(string: base)?.host ?? "Plex", type: .plex, baseURL: base, credentialRef: ref)
        do {
            source.capabilities = try await PlexProvider(source: source, token: t, http: http).validate()
            try catalog.save(source: source)
            try catalog.saveCapabilities(source.capabilities, sourceID: source.id)
            return source
        } catch {
            secure.remove(ref: ref)
            throw error
        }
    }

    /// TVHeadend: its playlist and guide are on fixed addresses and sign in with HTTP Basic, so one form is enough.
    func addTVHeadend(name: String, server: String, username: String, password: String) throws -> PlaylistSource {
        let base = try SourceURLValidator.validateXtreamServer(server)
        let s = try addM3U(name: name.nilIfEmpty ?? "TVHeadend " + (URL(string: base)?.host ?? ""), url: base + "/playlist/channels.m3u?profile=pass")
        do {
            if !username.isEmpty { try setHTTPAuth(s.id, kind: .basic, username: username, secret: password) }
            try setGuideURL(s.id, url: base + "/xmltv/channels")
        } catch { try? remove(s.id); throw error }
        return catalog_source(s.id) ?? s
    }

    private func catalog_source(_ id: UUID) -> PlaylistSource? { try? catalog.source(id: id) }

    func addM3U(name: String, url: String) throws -> PlaylistSource {
        let v = try SourceURLValidator.validateRemote(url)
        let ref = try secure.save(Credentials(url: v.full))
        let source = PlaylistSource(name: name.nilIfEmpty ?? URL(string: v.full)?.host ?? "Playlist", type: .m3uRemote, baseURL: v.display, credentialRef: ref)
        try catalog.save(source: source)
        return source
    }

    func addM3UFile(name: String, fileURL: URL) throws -> PlaylistSource {
        try SourceURLValidator.validateLocalFile(fileURL)
        let copied = try StorageService.shared.importPlaylistFile(fileURL)
        let source = PlaylistSource(name: name.nilIfEmpty ?? fileURL.deletingPathExtension().lastPathComponent, type: .m3uLocal, baseURL: copied.lastPathComponent)
        try catalog.save(source: source)
        return source
    }

    // MARK: editing / removing

    func rename(_ id: UUID, to name: String) throws {
        guard var s = try catalog.source(id: id) else { return }
        s.name = name.nilIfEmpty ?? s.name
        try catalog.save(source: s)
        invalidateProvider(id)
    }

    func setGuideURL(_ id: UUID, url: String?) throws {
        guard var s = try catalog.source(id: id) else { return }
        if let url = url.nilIfEmpty, !url.hasPrefix(XMLTVClient.localScheme + "://") { _ = try SourceURLValidator.validateRemote(url) }
        s.epgURL = url.nilIfEmpty
        try catalog.save(source: s)
        invalidateProvider(id)
    }

    /// Uses an XMLTV file (plain or .gz) from this device as the playlist's guide, instead of an address.
    func setGuideFile(_ id: UUID, fileURL: URL) throws {
        guard var s = try catalog.source(id: id) else { return }
        try SourceURLValidator.validateLocalFile(fileURL)
        let ext = fileURL.pathExtension.lowercased() == "gz" ? "xml.gz" : "xml"
        let name = "guide-\(id.uuidString.lowercased()).\(ext)"
        let dest = StorageService.importedPlaylists.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: fileURL, to: dest)
        s.epgURL = XMLTVClient.localAddress(forFile: name)
        try catalog.save(source: s)
        invalidateProvider(id)
    }

    /// An HDHomeRun tuner on the local network: its channel list is read from `/lineup.json`.
    func addHDHomeRun(name: String, host: String) throws -> PlaylistSource {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.contains("://") { h = "http://" + h }
        guard var c = URLComponents(string: h), c.host != nil else { throw SourceValidationError.invalid }
        c.path = "/lineup.json"
        guard let url = c.url?.absoluteString else { throw SourceValidationError.invalid }
        return try addM3U(name: name.nilIfEmpty ?? "HDHomeRun \(c.host ?? "")", url: url)
    }

    /// Replaces the saved login. Also used for a playlist restored from a backup, which has no login yet.
    func updateXtreamLogin(_ id: UUID, username: String, password: String) throws {
        guard var s = try catalog.source(id: id), s.type.hasLogin else { return }
        // Plex signs in with a token only, a Stalker portal with the box's MAC address only; the rest need both.
        var username = username
        switch s.type {
        case .plex: guard !password.isEmpty else { throw SourceValidationError.empty }; username = ""
        case .stalker: guard let mac = StalkerMapper.normalizedMAC(username) else { throw SourceValidationError.invalid }; username = mac
        default: guard !username.isEmpty, !password.isEmpty else { throw SourceValidationError.empty }
        }
        if let ref = s.credentialRef { try secure.store.save(Credentials(username: username, password: password), ref: ref) }
        else { s.credentialRef = try secure.save(Credentials(username: username, password: password)); try catalog.save(source: s) }
        invalidateProvider(id)
    }

    /// Sets the address of a remote M3U playlist (the full address, which may carry a token, goes to the Keychain).
    func updateM3UAddress(_ id: UUID, url: String) throws {
        guard var s = try catalog.source(id: id), s.type == .m3uRemote else { return }
        let v = try SourceURLValidator.validateRemote(url)
        if let ref = s.credentialRef { try secure.store.save(Credentials(url: v.full), ref: ref) }
        else { s.credentialRef = try secure.save(Credentials(url: v.full)) }
        s.baseURL = v.display
        try catalog.save(source: s)
        invalidateProvider(id)
    }

    /// True when the playlist has everything needed to connect (a saved login or address, or a local file).
    func hasCredentials(_ s: PlaylistSource) -> Bool {
        switch s.type {
        case .m3uLocal: return true
        case .xtream, .jellyfin, .emby, .stalker, .plex, .m3uRemote: return s.credentialRef != nil && secure.credentials(for: s) != nil
        }
    }

    func setEnabled(_ id: UUID, _ on: Bool) throws { try catalog.setEnabled(on, sourceID: id) }

    func remove(_ id: UUID) throws {
        if let s = try catalog.source(id: id) {
            secure.remove(ref: s.credentialRef)
            if s.type == .m3uLocal { try? FileManager.default.removeItem(at: StorageService.importedPlaylists.appendingPathComponent(s.baseURL)) }
        }
        try catalog.deleteSource(id: id)
        invalidateProvider(id)
    }

    // MARK: legacy import (earlier builds kept playlists, passwords included, in preferences)

    @discardableResult
    func importLegacyPreferences(_ defaults: UserDefaults = .standard) async -> [PlaylistSource] {
        guard let data = defaults.data(forKey: "playlists"),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var imported: [PlaylistSource] = []
        for item in items {
            guard let name = item["name"] as? String, let src = item["source"] as? String else { continue }
            do {
                if let c = URLComponents(string: src), c.path.hasSuffix("/get.php"),
                   let u = c.queryItems?.first(where: { $0.name == "username" })?.value,
                   let p = c.queryItems?.first(where: { $0.name == "password" })?.value,
                   let scheme = c.scheme, let host = c.host {
                    let server = "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
                    imported.append(try await addXtream(name: name, server: server, username: u, password: p, verify: false))
                } else if src.lowercased().hasPrefix("http") {
                    imported.append(try addM3U(name: name, url: src))
                } else if FileManager.default.fileExists(atPath: src) {
                    imported.append(try addM3UFile(name: name, fileURL: URL(fileURLWithPath: src)))
                }
            } catch { Log.app.error("legacy source skipped: \(error.localizedDescription)") }
        }
        // The old copy contains plaintext passwords: remove it once migrated.
        for k in ["playlists", "active", "favorites"] { defaults.removeObject(forKey: k) }
        return imported
    }

    // MARK: backup (non-sensitive configuration only)

    struct ExportedSource: Codable { var name: String; var type: String; var address: String; var guide: String? }

    func exportConfiguration() throws -> Data {
        let items = try catalog.sources().map { ExportedSource(name: $0.name, type: $0.type.rawValue, address: $0.baseURL, guide: $0.epgURL) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(items)
    }
}
