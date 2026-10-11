import Foundation

struct SearchCatalogUseCase: Sendable {
    let search: SearchService
    func callAsFunction(_ term: String, filters: SearchFilters = SearchFilters()) async throws -> SearchResults {
        try await search.search(term, filters: filters)
    }
}
