import Foundation

struct XMLTVDownload: Sendable {
    let xmlFile: URL?          // plain XML ready to parse; nil when the server said "not modified"
    let etag: String?
    let lastModified: String?
}

struct XMLTVClient: Sendable {
    let http: HTTPClient

    /// Downloads (conditional on ETag/Last-Modified) and decompresses if needed. Caller deletes `xmlFile`.
    func fetch(_ url: URL, etag: String?, lastModified: String?, headers: SourceHeaders = SourceHeaders(),
               progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> XMLTVDownload {
        if url.scheme == Self.localScheme { return try fetchLocal(url) }
        var req = http.builder.get(url, etag: etag, lastModified: lastModified)
        headers.apply(to: &req)
        let r = try await http.downloadWithRetry(req, maxBytes: http.config.maxEPGBytes, progress: progress)
        if r.notModified { return XMLTVDownload(xmlFile: nil, etag: etag, lastModified: lastModified) }
        guard let f = r.fileURL else { throw NetworkError.unreadable }
        if GzipInflater.isGzip(f) {
            let out = HTTPClient.tempDirectory.appendingPathComponent(UUID().uuidString + ".xml")
            defer { try? FileManager.default.removeItem(at: f) }
            do { try GzipInflater.inflate(from: f, to: out) }
            catch { try? FileManager.default.removeItem(at: out); throw error }
            return XMLTVDownload(xmlFile: out, etag: r.etag, lastModified: r.lastModified)
        }
        return XMLTVDownload(xmlFile: f, etag: r.etag, lastModified: r.lastModified)
    }

    /// A guide imported from a file is addressed as `local-guide://<file name>`, so it survives the app's folder moving.
    static let localScheme = "local-guide"
    static func localAddress(forFile name: String) -> String { "\(localScheme)://\(name)" }

    private func fetchLocal(_ url: URL) throws -> XMLTVDownload {
        let name = url.host(percentEncoded: false) ?? url.lastPathComponent
        let source = StorageService.importedPlaylists.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { throw SourceError.invalidResponse("The guide file is missing. Import it again in the playlist's settings.") }
        let out = HTTPClient.tempDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        if GzipInflater.isGzip(source) { try GzipInflater.inflate(from: source, to: out) }
        else { try FileManager.default.copyItem(at: source, to: out) }
        return XMLTVDownload(xmlFile: out, etag: nil, lastModified: nil)
    }
}
