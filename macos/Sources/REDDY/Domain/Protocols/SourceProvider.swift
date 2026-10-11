import Foundation

enum SourceError: LocalizedError, Sendable {
    case unsupported(String)
    case authFailed
    case expired
    case invalidResponse(String)
    case credentialsMissing
    case network(NetworkError)

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): "This source doesn't provide \(what)."
        case .authFailed: "The provider rejected the login. Check the username and password."
        case .expired: "The account is expired or inactive."
        case .invalidResponse(let m): "The provider returned data StreamSetu couldn't read. \(CredentialRedactor.redact(m))"
        case .credentialsMissing: "The saved login for this source could not be found. Edit the source and enter it again."
        case .network(let e): e.errorDescription
        }
    }
}

/// A uniform view over M3U playlists and Xtream-compatible servers. Collections are delivered in batches
/// so large catalogs are never forced through one giant array hand-off.
protocol SourceProvider: Sendable {
    var source: PlaylistSource { get }

    func validate() async throws -> SourceCapabilities
    func categories(_ kind: ContentKind) async throws -> [CatalogCategory]
    /// Categories plus what the provider listed and what had to be rejected, for diagnostics.
    func categoryFetch(_ kind: ContentKind) async throws -> CategoryFetch
    func channels() -> AsyncThrowingStream<[Channel], Error>
    func movies() -> AsyncThrowingStream<[Movie], Error>
    func series() -> AsyncThrowingStream<[Series], Error>
    func movieDetail(_ movie: Movie) async throws -> MovieDetail
    func seriesDetail(_ series: Series) async throws -> SeriesDetail
    func epgLocation() -> URL?
    func streamURL(kind: ContentKind, ref: String) throws -> URL
    /// Address of a past programme from the provider's archive, or nil when this provider has no catch-up.
    /// `utcOffsetMinutes` is the provider's own clock: archive addresses name the start time in it.
    func catchupURL(ref: String, start: Date, durationMinutes: Int, utcOffsetMinutes: Int) throws -> URL?
    /// For portals that hand out a short-lived link each time you play: asks for the real address. Only called for `PortalLink` addresses.
    func resolveLink(kind: ContentKind, ref: String) async throws -> URL
}

extension SourceProvider {
    func categories(_ kind: ContentKind) async throws -> [CatalogCategory] { [] }
    func categoryFetch(_ kind: ContentKind) async throws -> CategoryFetch {
        let c = try await categories(kind)
        return CategoryFetch(categories: c, providerCount: c.count, rejected: [])
    }
    func movies() -> AsyncThrowingStream<[Movie], Error> { .init { $0.finish() } }
    func series() -> AsyncThrowingStream<[Series], Error> { .init { $0.finish() } }
    func movieDetail(_ movie: Movie) async throws -> MovieDetail { throw SourceError.unsupported("movie details") }
    func seriesDetail(_ series: Series) async throws -> SeriesDetail { throw SourceError.unsupported("series details") }
}

extension AsyncThrowingStream where Element: Sendable, Failure == Error {
    /// Builds a stream from an async producer that yields batches; cancels the producer when the consumer stops.
    static func producing(_ body: @escaping @Sendable (Continuation) async throws -> Void) -> Self {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { try await body(continuation); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension SourceProvider {
    func resolveLink(kind: ContentKind, ref: String) async throws -> URL { throw SourceError.unsupported("links") }
    func catchupURL(ref: String, start: Date, durationMinutes: Int, utcOffsetMinutes: Int) throws -> URL? { nil }
}
