import Foundation

/// The results of searches asked in this session (memory only, a few minutes; see `MusicQueryCache`). One entry per source, chip and wording.
enum MusicSearchCache {
    static let chunks = MusicQueryCache<MusicSearchChunk>()

    /// The first page of a source's answer is cached; a later page ("load more") is always asked live.
    static func run(provider: any MusicMetadataProvider, query: String, kind: MusicSearchKind, page: MusicPagination?) async throws -> MusicSearchChunk {
        guard page == nil else { return try await MusicSearchRunner.run(provider: provider, query: query, kind: kind, page: nil) }
        let key = MusicQueryCache<MusicSearchChunk>.key(provider.id, MusicCatalogRuntime.shared.country ?? "", kind.rawValue, query)
        return try await chunks.value(for: key) { try await MusicSearchRunner.run(provider: provider, query: query, kind: kind, page: nil) }
    }
}
