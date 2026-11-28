import Foundation

// The section loaders of the album / soundtrack page, one per section. Each is a `MusicEntitySectionLoader`, so the shared entity model runs it once
// however many views hold the album (the page and the right panel's Related tab), keeps its phase, shows partial results while more land, cancels it
// when the page goes away, and re-runs it when the graph changes under it.
//
// A loader reads what the graph holds and reports it at once (`partial`), then asks the entity layer to enrich (through the hooks, bounded and
// single-flight on the other side) and reports the final result. None of them waits on the network for a first answer, and none touches the player.

private func result(_ items: [some Hashable & Sendable], sources: [MusicSourceID] = [], explanation: String? = nil) -> MusicSectionResult {
    MusicSectionResult(items: items.map { AnyHashable($0) }, provenance: sources.map { MusicSectionProvenance(source: $0) }, explanation: explanation)
}

/// An empty answer that came from failed reads is a failure (the model keeps the section's earlier items); a real empty answer is just empty.
private func finished(_ r: MusicSoundtrackReader, _ items: [some Hashable & Sendable], sources: [MusicSourceID] = []) throws -> MusicSectionResult {
    if items.isEmpty, r.failures.count > 0 { throw MusicSoundtrackError.storeUnavailable }
    return result(items, sources: sources)
}

struct MusicSoundtrackHeaderLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.header }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        guard let h = await MusicSoundtrackBuild.header(r, id: entity) else { return try finished(r, [MusicSoundtrackHeaderFacts]()) }
        return result([h])
    }
}

struct MusicSoundtrackCreditsLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.credits }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        let c = await MusicSoundtrackBuild.credits(r, id: entity)
        // The merged groups (overview chips) and the unmerged credits (the Credits pill) travel in one section; each reader picks its own type.
        let items: [AnyHashable] = c.groups.map { AnyHashable($0) } + c.raw.map { AnyHashable($0) }
        if items.isEmpty, r.failures.count > 0 { throw MusicSoundtrackError.storeUnavailable }
        return MusicSectionResult(items: items, provenance: c.sources.map { MusicSectionProvenance(source: $0) }, explanation: nil)
    }
}

struct MusicSoundtrackCastLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.cast }
    var hooks: MusicSoundtrackHooks = .none
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        var c = await MusicSoundtrackBuild.cast(r, id: entity, hooks: .none)
        if c.cast.isEmpty, c.film != nil {
            try Task.checkCancellation()
            c = await MusicSoundtrackBuild.cast(r, id: entity, hooks: hooks)
        }
        return try finished(r, c.cast, sources: c.sources)
    }
}

struct MusicSoundtrackMoreFilmsLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.moreFilms }
    var hooks: MusicSoundtrackHooks = .none
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        let first = await MusicSoundtrackBuild.moreFilms(r, id: entity)
        guard first.film != nil else { return try finished(r, [MusicSoundtrackFilmItem]()) }
        if !first.items.isEmpty { await report.partial(result(first.items)) }
        try Task.checkCancellation()
        let final = await MusicSoundtrackBuild.moreFilms(r, id: entity, hooks: hooks, enrichActors: true)
        return try finished(r, final.items)
    }
}

struct MusicSoundtrackOfCastLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.soundtracksOfCast }
    var hooks: MusicSoundtrackHooks = .none
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        let first = await MusicSoundtrackBuild.moreFilms(r, id: entity)
        guard first.film != nil else { return try finished(r, [MusicSoundtrackAlbum]()) }
        let early = await MusicSoundtrackBuild.soundtracksOfCast(r, films: first.items)
        if !early.isEmpty { await report.partial(result(early)) }
        try Task.checkCancellation()
        let enriched = await MusicSoundtrackBuild.moreFilms(r, id: entity, hooks: hooks, enrichActors: true)
        let final = await MusicSoundtrackBuild.soundtracksOfCast(r, films: enriched.items, hooks: hooks, useProvider: hooks.providerAlbums != nil)
        return try finished(r, final)
    }
}

struct MusicSoundtrackMoreByComposersLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.moreByComposers }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        return try finished(r, await MusicSoundtrackBuild.moreByComposers(r, id: entity))
    }
}

struct MusicSoundtrackMoreBySingersLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.moreBySingers }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        return try finished(r, await MusicSoundtrackBuild.moreBySingers(r, id: entity))
    }
}

struct MusicSoundtrackRelatedLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.related }
    var hooks: MusicSoundtrackHooks = .none
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        return try finished(r, await MusicSoundtrackBuild.related(r, id: entity, hooks: hooks))
    }
}

struct MusicSoundtrackClassicLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.classic }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        return try finished(r, await MusicSoundtrackBuild.classic(r, id: entity))
    }
}

struct MusicSoundtrackExploreLoader: MusicEntitySectionLoader {
    var key: String { MusicSoundtrackKey.explore }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let r = MusicSoundtrackReader(store)
        guard let header = await MusicSoundtrackBuild.header(r, id: entity) else { return try finished(r, [MusicSoundtrackLink]()) }
        let credits = await MusicSoundtrackBuild.credits(r, id: entity)
        let cast = header.film == nil ? nil : await MusicSoundtrackBuild.cast(r, id: entity)
        return result(MusicSoundtrackBuild.explore(header: header, credits: credits, cast: cast))
    }
}

/// Every loader of the page, with the hooks the page gives them.
enum MusicSoundtrackLoaders {
    static func all(hooks: MusicSoundtrackHooks) -> [any MusicEntitySectionLoader] {
        [MusicSoundtrackHeaderLoader(), MusicSoundtrackCreditsLoader(), MusicSoundtrackCastLoader(hooks: hooks), MusicSoundtrackMoreFilmsLoader(hooks: hooks),
         MusicSoundtrackOfCastLoader(hooks: hooks), MusicSoundtrackMoreByComposersLoader(), MusicSoundtrackMoreBySingersLoader(), MusicSoundtrackRelatedLoader(hooks: hooks),
         MusicSoundtrackClassicLoader(), MusicSoundtrackExploreLoader()]
    }
}
