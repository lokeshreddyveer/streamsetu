import Foundation

struct BrowseCatalogUseCase: Sendable {
    let catalog: CatalogRepository

    func channels(_ q: ChannelQuery) async throws -> [Channel] { try await Task.detached { [catalog] in try catalog.channels(q) }.value }
    func movies(_ q: VODQuery) async throws -> [Movie] { try await Task.detached { [catalog] in try catalog.movies(q) }.value }
    func series(_ q: VODQuery) async throws -> [Series] { try await Task.detached { [catalog] in try catalog.series(q) }.value }
    func categories(_ kind: ContentKind, source: UUID? = nil) async throws -> [CatalogCategory] {
        try await Task.detached { [catalog] in try catalog.categories(sourceID: source, kind: kind, includeHidden: false) }.value
    }
}
