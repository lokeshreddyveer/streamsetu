import Foundation
import Testing
@testable import REDDY

/// Runs a loader against a store and returns what it found, as one type.
func g8Run<T: Hashable>(_ loader: any MusicEntitySectionLoader, _ id: MusicEntityID, _ store: any MusicGraphStoring, as type: T.Type) async throws -> [T] {
    let r = try await loader.load(entity: id, store: store, report: MusicSectionReporter { _ in })
    return r.items.compactMap { $0.base as? T }
}

/// Polls until the condition holds (the entity model loads on tasks of its own).
@MainActor func g8Wait(_ what: String = "condition", seconds: Double = 5, _ cond: @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
}

/// A small hand-made graph for the cases the recorded fixtures do not cover.
struct G8Graph {
    let store = MusicInMemoryGraph()
    static let wd = MusicProvenance(source: .wikidata, license: .cc0, score: 0.95, evidence: [MusicProvenance.statedToken])
    static let matcher = MusicProvenance(source: .matcher, license: .derived, score: 0.9, evidence: ["title", "composer"])

    @discardableResult func put(_ kind: MusicEntityKind, _ name: String, year: Int? = nil, lang: String? = nil, ids: [ExternalID] = [], attrs: [String: String] = [:],
                                subkind: String? = nil, provisional: Bool = false) async throws -> MusicEntityID {
        try await store.upsert(MusicEntityDraft(kind: kind, name: name, subkind: subkind, lang: lang, year: year, attrs: attrs,
                                                externalIDs: ids.isEmpty ? [ExternalID(.canon, kind.slug + "|" + name + "|\(year ?? 0)")] : ids, provisional: provisional)).id
    }
    func film(_ name: String, _ year: Int, lang: String = "hi", tmdb: Int? = nil) async throws -> MusicEntityID {
        try await put(.film, name, year: year, lang: lang, ids: tmdb.map { [ExternalID(.tmdbMovie, String($0))] } ?? [ExternalID(.wikidata, "Q" + String(abs((name + "\(year)").hashValue % 90_000_000)))])
    }
    func person(_ name: String, year: Int? = nil) async throws -> MusicEntityID {
        try await put(.person, name, year: year, ids: [ExternalID(.wikidata, "Q" + String(abs((name + "\(year ?? 0)").hashValue % 90_000_000)))])
    }
    func edge(_ s: MusicEntityID, _ p: MusicPredicate, _ o: MusicEntityID, role: MusicRole? = nil, order: Int? = nil, attrs: EdgeAttributes = [:], prov: MusicProvenance = G8Graph.wd) async throws {
        var e = MusicEdge(subject: s, predicate: p, object: o, qualifier: role?.rawValue ?? "", attributes: attrs, creditLevel: .film, order: order)
        e.order = order
        _ = try await store.addEdge(e, provenance: prov)
    }
    func cast(_ film: MusicEntityID, _ people: [MusicEntityID]) async throws {
        for (i, p) in people.enumerated() { try await edge(film, .hasCast, p, role: .actor, order: i) }
    }
}

/// A fake host bridge: a set of films "in the library", a record of what was opened.
@MainActor final class FakeWatchBridge {
    var library: Set<Int> = []
    private(set) var opened: [MusicFilmWatchRef] = []
    private(set) var asked = 0
    var logic: MusicFilmWatchLogic {
        MusicFilmWatchLogic(isInLibrary: { [self] r in asked += 1; return r.tmdbID.map { library.contains($0) } ?? false },
                            open: { [self] r in guard let t = r.tmdbID, library.contains(t) else { return false }; opened.append(r); return true })
    }
}

/// Centers live for the whole test run: a model's tasks may finish after its test returns, and a model holds its store unowned.
@MainActor private var g8Centers: [MusicEntityModelCenter] = []
@MainActor func g8Center(_ store: any MusicGraphStoring) -> MusicEntityModelCenter {
    let c = MusicEntityModelCenter(store: MusicEntityStore(graph: store), graceWindow: .seconds(1), sleeper: { _ in try await Task.sleep(nanoseconds: 1_000_000) })
    g8Centers.append(c)
    return c
}
