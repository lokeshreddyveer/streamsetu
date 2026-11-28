import Foundation

// Reads of the graph the album / soundtrack page needs, as small async functions over `MusicGraphStoring`. Every read is local (no network) and every
// failure reads as "nothing there": a store that is busy, closed or failing makes a section empty, never an error on screen. Bounded: no read asks for
// more than the limits in `MusicSoundtrackLimits`, and the reads that fan out run a few at a time.

/// The entities that stand for the opened album: the release a provider showed, the album concept it is an edition of, and (for an album concept) its
/// editions. Credits, the film link and the tracklist are looked up on all of them, so it does not matter which one the route carries.
struct MusicSoundtrackFamily: Hashable, Sendable {
    var id: MusicEntityID
    var members: [MusicEntityID]
    /// Where tracks hang: the entity itself, its editions (for an album) or its parent album (for a release).
    var trackOwners: [MusicEntityID]
}

/// One recording on the release, in tracklist order.
struct MusicSoundtrackRecording: Hashable, Sendable {
    var id: MusicEntityID
    var title: String
    var durationMs: Int?
    var disc: Int?
    var position: Int?
    var versionKind: MusicVersionKind?
    var status: EdgeStatus
    var confidence: Float
}

/// Names already read in one page load (a name is looked up once however many sections need it).
final class MusicSoundtrackNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [MusicEntityID: String] = [:]
    func get(_ id: MusicEntityID) -> String? { lock.withLock { names[id] } }
    func set(_ id: MusicEntityID, _ name: String) { lock.withLock { names[id] = name } }
}

/// Counts reads the store failed (a closed, busy or failing store). A failed read reads as "nothing there", so a section that comes back empty
/// after a failure is reported as failed (the model then keeps what the section showed before), never as empty.
final class MusicSoundtrackFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func note() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

enum MusicSoundtrackError: Error, Equatable, Sendable { case storeUnavailable }

struct MusicSoundtrackReader: Sendable {
    let store: any MusicGraphStoring
    let names = MusicSoundtrackNameCache()
    let failures = MusicSoundtrackFailureCounter()
    init(_ store: any MusicGraphStoring) { self.store = store }

    /// The name of an entity (cached for this reader).
    func name(_ id: MusicEntityID) async -> String? {
        if let n = names.get(id) { return n }
        guard let s = await entity(id) else { return nil }
        names.set(id, s.name)
        return s.name
    }

    // MARK: primitives

    func entity(_ id: MusicEntityID) async -> MusicEntitySnapshot? {
        do { return try await store.entity(id) } catch { failures.note(); return nil }
    }

    /// The live edges of one entity (retracted ones are never returned; a tombstone is dropped again here as a guard).
    func edges(_ id: MusicEntityID, _ predicate: MusicPredicate? = nil, _ direction: MusicEdgeDirection = .outgoing, limit: Int = 100) async -> [MusicEdge] {
        do { return try await store.edges(of: id, predicate: predicate, direction: direction, limit: limit).filter { !$0.tombstone } } catch { failures.note(); return [] }
    }

    /// Runs `body` over `items` a few at a time, keeping the order of `items` in the result.
    func boundedMap<T: Sendable, R: Sendable>(_ items: [T], width: Int = MusicSoundtrackLimits.readConcurrency,
                                              _ body: @escaping @Sendable (T) async -> R) async -> [R] {
        var out: [R?] = Array(repeating: nil, count: items.count)
        var next = 0
        await withTaskGroup(of: (Int, R).self) { group in
            func launch() {
                guard next < items.count else { return }
                let i = next, item = items[i]
                next += 1
                group.addTask { (i, await body(item)) }
            }
            for _ in 0..<max(1, width) { launch() }
            while let (i, r) = await group.next() {
                out[i] = r
                if !Task.isCancelled { launch() }
            }
        }
        return out.compactMap { $0 }
    }

    // MARK: people

    /// The text that tells two people of one name apart, language-neutral: a description when the source gave one, else the years, else the country.
    static func rawDetail(_ s: MusicEntitySnapshot) -> String? {
        if let d = s.attrs["disambiguation"] ?? s.attrs["description"], !d.isEmpty { return d }
        if let y = s.year { return s.yearEnd.map { "\(y)–\($0)" } ?? "\(y)" }
        if let c = s.country, !c.isEmpty { return c }
        return nil
    }

    func person(_ id: MusicEntityID) async -> MusicSoundtrackPerson? {
        guard let s = await entity(id), s.kind.isAgent, !MusicCompilationArtist.isCompilation(s.name) else { return nil }
        // The name in the script the person reads (their listening, or the artist's own language) when the graph holds it, so a Telugu composer is not romanized.
        let aliases = ((try? await store.aliases(of: s.id)) ?? []).map(\.text)
        let name = MusicNativeNames.displayName(s.name, aliases: aliases, entityLanguage: s.lang, preferred: MusicNativeNames.shared.preferredLanguages)
        return MusicSoundtrackPerson(id: s.id, name: name, imageRef: s.imageRef, detail: Self.rawDetail(s))
    }

    // MARK: the album, its family and its film

    func family(of id: MusicEntityID) async -> MusicSoundtrackFamily {
        var members = [id]
        var owners = [id]
        if id.kind == .release {
            let parents = await edges(id, .editionOf, .outgoing, limit: 4).map(\.object)
            for p in parents where !members.contains(p) { members.append(p); owners.append(p) }
        } else if id.kind == .album {
            let editions = await edges(id, .editionOf, .incoming, limit: 12).map(\.subject)
            for e in editions where !members.contains(e) { members.append(e); owners.append(e) }
        }
        return MusicSoundtrackFamily(id: id, members: members, trackOwners: owners)
    }

    /// The film the album is the soundtrack of: the best `soundtrackOf` edge of any family member. A verified edge wins, then confidence. A conflicted
    /// edge is ignored; an inferred one below the minimum confidence is ignored (the page then shows no film at all, never a guess).
    func filmLink(_ family: MusicSoundtrackFamily) async -> MusicSoundtrackFilm? {
        var best: MusicEdge?
        for m in family.members {
            for e in await edges(m, .soundtrackOf, .outgoing, limit: 8) where Self.acceptsFilmLink(e) {
                if best == nil || Self.better(e, than: best!) { best = e }
            }
        }
        guard let best, let film = await filmRef(best.object, status: best.status, confidence: best.confidence) else { return nil }
        return film
    }

    static func acceptsFilmLink(_ e: MusicEdge) -> Bool {
        guard !e.tombstone, e.status != .conflicted else { return false }
        return e.status == .verified || e.confidence >= MusicSoundtrackLimits.minFilmLinkConfidence
    }

    static func better(_ a: MusicEdge, than b: MusicEdge) -> Bool {
        if (a.status == .verified) != (b.status == .verified) { return a.status == .verified }
        return a.confidence > b.confidence
    }

    func filmRef(_ id: MusicEntityID, status: EdgeStatus = .verified, confidence: Float = 1) async -> MusicSoundtrackFilm? {
        guard let s = await entity(id), s.kind == .film || s.kind == .series else { return nil }
        return MusicSoundtrackFilm(id: s.id, title: s.name, year: s.year, language: s.lang, imageRef: s.imageRef, linkStatus: status, linkConfidence: confidence)
    }

    /// The name of a facet node (language, era, genre) an entity points at, with its id.
    func facet(of members: [MusicEntityID], _ predicate: MusicPredicate) async -> (id: MusicEntityID, name: String)? {
        for m in members {
            for e in await edges(m, predicate, .outgoing, limit: 4) {
                if let s = await entity(e.object) { return (s.id, s.name) }
            }
        }
        return nil
    }

    // MARK: the tracklist

    /// The recordings on the release, in order, one per song (the editions of one album do not repeat a song).
    func recordings(_ family: MusicSoundtrackFamily, limit: Int = 200) async -> [MusicSoundtrackRecording] {
        var found: [MusicSoundtrackRecording] = []
        var seen = Set<String>()      // titles of the songs of the owners already read: a later edition repeats them
        var seenIDs = Set<MusicEntityID>()
        for owner in family.trackOwners {
            var ownTitles = Set<String>()
            let tracks = await edges(owner, .trackOn, .incoming, limit: limit)
            let loaded: [MusicSoundtrackRecording?] = await boundedMap(tracks) { e in
                guard e.status != .conflicted, let s = await self.entity(e.subject) else { return nil }
                return MusicSoundtrackRecording(id: s.id, title: s.name, durationMs: s.durationMs, disc: e.attributes.disc, position: e.attributes.position ?? e.order,
                                                versionKind: s.attrs["versionKind"].flatMap(MusicVersionKind.init(rawValue:)), status: e.status, confidence: e.confidence)
            }
            for r in loaded.compactMap({ $0 }) {
                // Within one release a song is told apart by its id, so two different recordings with one title ("Interlude" twice) both stay. A song of a later edition that
                // repeats a title of an earlier owner is the same song again and is dropped.
                guard seenIDs.insert(r.id).inserted else { continue }
                let key = MusicGraphText.latin(r.title)
                if seen.contains(key) { continue }
                ownTitles.insert(key)
                found.append(r)
            }
            seen.formUnion(ownTitles)
        }
        return found.sorted {
            let a = ($0.disc ?? 1, $0.position ?? Int.max), b = ($1.disc ?? 1, $1.position ?? Int.max)
            return a != b ? a < b : $0.title < $1.title
        }
    }
}
