import Foundation

/// Maps an Enigma2 (OpenWebif) `getallservices` reply into channels. Pure, so it is tested without a receiver.
struct Enigma2Mapper: Sendable {
    let source: PlaylistSource

    /// Normal TV and radio services start "1:0:". Markers ("1:64:") and directories ("1:832:") are not channels.
    static func isChannel(_ ref: String) -> Bool { ref.hasPrefix("1:0:") }

    func channels(_ json: [String: Any]) -> (channels: [Channel], bouquets: [(id: String, name: String)]) {
        var out: [Channel] = [], bouquets: [(String, String)] = [], order = 0
        var seen = Set<String>()
        for b in (json["services"] as? [[String: Any]]) ?? [] {
            let bname = CategoryNormalizer.clean((b["servicename"] as? String) ?? "Channels")
            let cid = CatalogCategory.makeID(source: source.id, kind: .channel, provider: bname)
            var any = false
            for s in (b["subservices"] as? [[String: Any]]) ?? [] {
                guard let ref = s["servicereference"] as? String, Self.isChannel(ref), let raw = s["servicename"] as? String, !raw.isEmpty, seen.insert(ref).inserted else { continue }
                let name = MetadataNormalizer.cleanDisplay(raw)
                out.append(Channel(id: ItemID.make(source: source.id, kind: .channel, provider: ref), sourceID: source.id, providerID: ref, name: name,
                                   normalizedName: MetadataNormalizer.normalize(name), categoryID: cid, categoryName: bname, logoURL: nil, epgID: nil, language: nil,
                                   country: CategoryNormalizer.countryPrefix(name), resolutionHint: MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(name)),
                                   sortOrder: order, streamRef: ref, groupKey: nil))
                order += 1; any = true
            }
            if any { bouquets.append((cid, bname)) }
        }
        return (out, bouquets)
    }
}

/// Enigma2 satellite and cable receivers with the OpenWebif interface: channels by bouquet, streamed from the receiver's own stream port.
final class Enigma2Provider: SourceProvider, @unchecked Sendable {
    let source: PlaylistSource
    private let base: String
    private let user: String?
    private let pass: String?
    private let http: HTTPClient
    private let headers: SourceHeaders
    private let mapper: Enigma2Mapper
    static let streamPort = 8001

    init(source: PlaylistSource, user: String?, pass: String?, http: HTTPClient, headers: SourceHeaders = SourceHeaders()) {
        self.source = source; self.base = source.baseURL; self.user = user; self.pass = pass; self.http = http; self.headers = headers
        mapper = Enigma2Mapper(source: source)
    }

    private func get(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw NetworkError.invalidURL }
        var r = http.builder.get(url)
        if let user, !user.isEmpty { r.setValue("Basic " + Data("\(user):\(pass ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        headers.apply(to: &r)
        do {
            let data = try await http.data(r, maxBytes: 32 * 1024 * 1024)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceError.invalidResponse("Unexpected reply from the receiver.") }
            return obj
        } catch let e as NetworkError { throw e.isAuthFailure ? SourceError.authFailed : SourceError.network(e) }
    }

    func validate() async throws -> SourceCapabilities {
        let m = mapper.channels(try await get("/api/getallservices"))
        guard !m.channels.isEmpty else { throw SourceError.invalidResponse("The receiver listed no channels. Is OpenWebif turned on?") }
        return SourceCapabilities(live: true, movies: false, series: false, epg: false, outputFormats: [])
    }

    func categoryFetch(_ kind: ContentKind) async throws -> CategoryFetch {
        guard kind == .channel else { return CategoryFetch(categories: [], providerCount: 0, rejected: []) }
        let b = mapper.channels(try await get("/api/getallservices")).bouquets
        let cats = b.enumerated().map { CatalogCategory(id: $1.id, sourceID: source.id, kind: .channel, providerID: $1.name, name: $1.name, sortOrder: $0) }
        return CategoryFetch(categories: cats, providerCount: cats.count, rejected: [])
    }

    func channels() -> AsyncThrowingStream<[Channel], Error> {
        .producing { [self] c in for b in mapper.channels(try await get("/api/getallservices")).channels.chunked(into: 2000) { c.yield(b) } }
    }

    func epgLocation() -> URL? { source.epgURL.flatMap(URL.init(string:)) }

    /// The receiver's stream port serves each service at `http://host:8001/<service reference>`, with the login in the address when it has one.
    func streamURL(kind: ContentKind, ref: String) throws -> URL {
        guard kind == .channel, var c = URLComponents(string: base) else { throw SourceError.unsupported("this kind of stream") }
        c.scheme = "http"; c.port = Self.streamPort; c.path = "/" + ref; c.query = nil
        if let user, !user.isEmpty { c.user = user; c.password = pass }
        guard let url = c.url else { throw NetworkError.invalidURL }
        return url
    }

    func catchupURL(ref: String, start: Date, durationMinutes: Int, utcOffsetMinutes: Int) throws -> URL? { nil }
}
