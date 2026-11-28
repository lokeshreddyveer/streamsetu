import Foundation

// The film page's section loaders (one per section key). Each reads the graph through the store it is handed and nothing else, so a page, a test and
// the right panel can run the same one. The entity model runs a loader once however many views ask.

struct MusicFilmOverviewLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.overview }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        guard let o = try await MusicFilmGraphReading.overview(film: entity, store: store) else { return MusicSectionResult() }
        return MusicSectionResult(items: [o], provenance: [])
    }
}

struct MusicFilmCastLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.cast }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let cast = try await MusicFilmGraphReading.cast(film: entity, store: store, report: { await report.partial($0) })
        return MusicSectionResult(items: cast.map { $0 as AnyHashable }, provenance: MusicFilmSectionProvenance.of(cast))
    }
}

struct MusicFilmCrewLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.crew }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let crew = try await MusicFilmGraphReading.crew(film: entity, store: store)
        return MusicSectionResult(items: crew.map { $0 as AnyHashable }, provenance: MusicFilmSectionProvenance.of(crew.flatMap(\.people)))
    }
}

struct MusicFilmSoundtracksLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.soundtracks }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let albums = try await MusicFilmGraphReading.soundtrackAlbums(film: entity, store: store)
        let status = albums.contains { $0.status == .verified } ? EdgeStatus.verified : EdgeStatus.inferred
        return MusicSectionResult(items: albums.map { $0 as AnyHashable }, provenance: albums.isEmpty ? [] : [MusicSectionProvenance(status: status)])
    }
}

struct MusicFilmSongsLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.songs }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let albums = try await MusicFilmGraphReading.soundtrackAlbums(film: entity, store: store)
        let songs = try await MusicFilmGraphReading.songs(albums: albums, store: store, report: { await report.partial($0) })
        return MusicSectionResult(items: songs.map { $0 as AnyHashable })
    }
}

struct MusicFilmVersionsLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.versions }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let albums = try await MusicFilmGraphReading.soundtrackAlbums(film: entity, store: store)
        let v = try await MusicFilmGraphReading.versions(film: entity, albums: albums, store: store)
        return MusicSectionResult(items: v.map { $0 as AnyHashable })
    }
}

struct MusicFilmRelatedLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.related }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        MusicSectionResult(items: try await MusicFilmRelatedReading.related(film: entity, store: store).map { $0 as AnyHashable })
    }
}

struct MusicFilmDirectorFilmsLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.directorFilms }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        MusicSectionResult(items: try await MusicFilmRelatedReading.moreByDirector(film: entity, store: store).map { $0 as AnyHashable })
    }
}

struct MusicFilmComposerMusicLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.composerMusic }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        MusicSectionResult(items: try await MusicFilmRelatedReading.composerMusic(film: entity, store: store).map { $0 as AnyHashable })
    }
}

struct MusicFilmCastMusicLoader: MusicEntitySectionLoader {
    var key: String { MusicFilmSectionKey.castMusic }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        MusicSectionResult(items: try await MusicFilmRelatedReading.castMusic(film: entity, store: store).map { $0 as AnyHashable })
    }
}

enum MusicFilmLoaders {
    static let core: [any MusicEntitySectionLoader] = [MusicFilmOverviewLoader(), MusicFilmCastLoader(), MusicFilmCrewLoader(), MusicFilmSoundtracksLoader(),
                                                       MusicFilmSongsLoader(), MusicFilmVersionsLoader()]
    static func lazy(_ key: String) -> (any MusicEntitySectionLoader)? {
        switch key {
        case MusicFilmSectionKey.related: MusicFilmRelatedLoader()
        case MusicFilmSectionKey.directorFilms: MusicFilmDirectorFilmsLoader()
        case MusicFilmSectionKey.composerMusic: MusicFilmComposerMusicLoader()
        case MusicFilmSectionKey.castMusic: MusicFilmCastMusicLoader()
        default: nil
        }
    }
}

enum MusicFilmSectionProvenance {
    /// The strongest status among the credits and the attribution names they carry, for the section's footnote.
    static func of(_ people: [MusicFilmPersonItem]) -> [MusicSectionProvenance] {
        guard !people.isEmpty else { return [] }
        let status: EdgeStatus = people.contains { $0.status == .verified } ? .verified : .inferred
        let notes = Set(people.compactMap(\.attribution)).sorted().joined(separator: ", ")
        return [MusicSectionProvenance(status: status, note: notes.isEmpty ? nil : notes)]
    }
}
