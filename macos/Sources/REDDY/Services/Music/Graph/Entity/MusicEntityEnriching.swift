import Foundation

/// What an enrichment run changed: the entities whose rows or edges are different now. The store announces them so open pages refresh.
struct MusicEnrichmentResult: Sendable, Equatable {
    var changed: Set<MusicEntityID> = []
    static let none = MusicEnrichmentResult()
}

/// The hook the metadata resolver and the credits ingest plug into (G2, G3, G5 to G8). The navigation layer calls it once per entity model, in the
/// background, when a page opens an entity the graph holds only provisionally or has not enriched; it never sits on the playback path. The defaults
/// do nothing, so a build without those packages behaves exactly as before.
protocol MusicEntityEnriching: Sendable {
    func enrichTrack(_ id: MusicEntityID) async throws -> MusicEnrichmentResult
    func enrichAlbum(_ id: MusicEntityID) async throws -> MusicEnrichmentResult
    func enrichFilm(_ id: MusicEntityID) async throws -> MusicEnrichmentResult
    func enrichPerson(_ id: MusicEntityID) async throws -> MusicEnrichmentResult
}

extension MusicEntityEnriching {
    func enrichTrack(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { .none }
    func enrichAlbum(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { .none }
    func enrichFilm(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { .none }
    func enrichPerson(_ id: MusicEntityID) async throws -> MusicEnrichmentResult { .none }

    /// Picks the entry point for an entity's kind. Facet kinds, stations and playlists have nothing to enrich.
    func enrich(_ id: MusicEntityID) async throws -> MusicEnrichmentResult {
        switch id.kind {
        case .recording, .work, .track: try await enrichTrack(id)
        case .album, .release: try await enrichAlbum(id)
        case .film, .series: try await enrichFilm(id)
        case .person, .group: try await enrichPerson(id)
        case .playlist, .genre, .language, .region, .era, .station: .none
        }
    }
}

struct MusicNoopEntityEnricher: MusicEntityEnriching {
    init() {}
}
