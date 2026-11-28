import Foundation
import Observation

// What the album page adds to the soundtrack page's own sections: the other versions of the album, the facts of the release, the composer and lyricist of
// each song (only where the recording itself carries them), and the local choices (preferred edition, hidden editions). Every read is local graph data;
// nothing here is invented, and a part with no data stays empty so the page can hide it.

// MARK: values

struct MusicAlbumVersion: Hashable, Sendable, Identifiable {
    enum Category: Int, Hashable, Sendable, CaseIterable { case edition = 0, language, soundtrack, related }
    var id: MusicEntityID
    var facts: MusicAlbumEditionFacts
    var badge: MusicAlbumEditionBadge
    var category: Category
    var imageRef: String?
}

struct MusicAlbumInfo: Hashable, Sendable {
    var description: String?
    var label: String?
    var catalogueNumber: String?
    var barcode: String?
    var copyright: String?
    var releaseDate: String?
    var originalYear: Int?
    var language: String?
    var genres: [String] = []
    var isEmpty: Bool {
        description == nil && label == nil && catalogueNumber == nil && barcode == nil && copyright == nil && releaseDate == nil && language == nil && genres.isEmpty
    }
}

struct MusicAlbumTrackMakers: Hashable, Sendable {
    var composers: [String] = []
    var lyricists: [String] = []
    var isEmpty: Bool { composers.isEmpty && lyricists.isEmpty }
}

// MARK: local choices

/// The person's local album choices. Stored on this device only; nothing is deleted when an edition is hidden or preferred.
struct MusicAlbumPrefs: Codable, Equatable, Sendable {
    var preferred: [String: String] = [:]
    var hidden: [String] = []
    /// The person's own rating (1 to 5), note and collection tags of an album, by the album concept's id.
    var ratings: [String: Int] = [:]
    var notes: [String: String] = [:]
    var tags: [String: [String]] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey { case preferred, hidden, ratings, notes, tags }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferred = try c.decodeIfPresent([String: String].self, forKey: .preferred) ?? [:]
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        ratings = try c.decodeIfPresent([String: Int].self, forKey: .ratings) ?? [:]
        notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        tags = try c.decodeIfPresent([String: [String]].self, forKey: .tags) ?? [:]
    }

    /// The edition an album opened from a provider value should land on: the one the person marked as preferred for its album, when that is a different, not hidden
    /// edition. Nil keeps the page that was asked for. Only provider-value opens use this; the Versions list and Compare always open the edition they name.
    func preferredRedirect(from entity: MusicEntityID, concept: MusicEntityID?) -> MusicEntityID? {
        guard let raw = preferred[(concept ?? entity).rawValue], let id = MusicEntityID(rawValue: raw), id != entity, !isHidden(id) else { return nil }
        return id
    }

    private static let key = "music.album.prefs.v1"
    static func load() -> MusicAlbumPrefs {
        guard let d = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode(MusicAlbumPrefs.self, from: d) else { return MusicAlbumPrefs() }
        return p
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }

    func isHidden(_ id: MusicEntityID) -> Bool { hidden.contains(id.rawValue) }
    mutating func setHidden(_ id: MusicEntityID, _ on: Bool) {
        hidden.removeAll { $0 == id.rawValue }
        if on { hidden.append(id.rawValue) }
    }
}

// MARK: reads

enum MusicAlbumReads {
    /// The album concept an opened release belongs to (or the album itself).
    static func albumConcept(_ r: MusicSoundtrackReader, _ id: MusicEntityID) async -> MusicEntityID? {
        if id.kind == .album { return id }
        return await r.edges(id, .editionOf, .outgoing, limit: 2).first?.object
    }

    static func editionFacts(_ r: MusicSoundtrackReader, _ id: MusicEntityID, dub: String?) async -> (MusicAlbumEditionFacts, String?)? {
        guard let s = await r.entity(id) else { return nil }
        let n = await trackEdges(r, id).count
        return (MusicAlbumEditionFacts(id: id.rawValue, title: s.name, year: s.year, trackCount: n, dubLanguage: dub), s.imageRef)
    }

    /// The `trackOn` edges of an album page's tracklist, read where tracks hang: on the release itself, on its editions (for an album concept) or on the parent
    /// album (for a release). A song listed on two of them counts once.
    static func trackEdges(_ r: MusicSoundtrackReader, _ id: MusicEntityID) async -> [MusicEdge] {
        var seen = Set<MusicEntityID>()
        var out: [MusicEdge] = []
        for owner in await r.family(of: id).trackOwners {
            for e in await r.edges(owner, .trackOn, .incoming, limit: 300) where e.status != .conflicted && seen.insert(e.subject).inserted { out.append(e) }
        }
        return out
    }

    /// Other versions: editions of the same album concept (documented `editionOf`), language / dub editions and sibling soundtracks of the same film
    /// (documented `soundtrackOf` edges), and albums a source lists as related. Never matched by title and artist alone.
    static func versions(_ r: MusicSoundtrackReader, entity: MusicEntityID) async -> [MusicAlbumVersion] {
        let family = await r.family(of: entity)
        var out: [MusicAlbumVersion] = []
        // The page itself is never its own version. A release page also leaves out its parent album; an album page lists its editions (they are the versions).
        var seen: Set<MusicEntityID> = [entity]
        if entity.kind != .album { seen.formUnion(family.members) }
        var all: [MusicAlbumEditionFacts] = []
        var pending: [(MusicEntityID, MusicAlbumVersion.Category, String?, String?, MusicAlbumEditionFacts)] = []

        func add(_ id: MusicEntityID, _ cat: MusicAlbumVersion.Category, dub: String?) async {
            guard seen.insert(id).inserted, let (f, img) = await editionFacts(r, id, dub: dub) else { return }
            pending.append((id, cat, img, dub, f))
            if cat == .edition || cat == .language { all.append(f) }   // only documented editions can make a badge; a merely related album cannot
        }
        // editions of the album concept (the opened release is one of them and is the subject's own row, so it is not listed)
        if let concept = await albumConcept(r, entity) {
            for e in await r.edges(concept, .editionOf, .incoming, limit: 24) where e.status != .conflicted && e.subject != entity {
                let dub = await r.edges(e.subject, .soundtrackOf, .outgoing, limit: 4).compactMap { $0.attributes.dubLanguage }.first
                await add(e.subject, dub == nil ? .edition : .language, dub: dub)
            }
        }
        // sibling soundtracks of the same film
        if let film = await r.filmLink(family) {
            for e in await r.edges(film.id, .soundtrackOf, .incoming, limit: 40) where MusicSoundtrackReader.acceptsFilmLink(e) {
                let sub = e.subject
                if family.members.contains(sub) { continue }
                var id = sub
                if sub.kind == .release, let parent = await r.edges(sub, .editionOf, .outgoing, limit: 1).first?.object {
                    if family.members.contains(parent) { continue }
                    id = parent
                }
                await add(id, e.attributes.dubLanguage == nil ? .soundtrack : .language, dub: e.attributes.dubLanguage)
            }
        }
        for e in await r.edges(entity, .relatedAlbum, .outgoing, limit: 12) where e.status != .conflicted {
            await add(e.object, .related, dub: nil)
        }
        // the subject's own facts, so a badge can be told against its siblings
        if let (own, _) = await editionFacts(r, entity, dub: nil) { all.append(own) }
        for (id, cat, img, _, f) in pending {
            out.append(MusicAlbumVersion(id: id, facts: f, badge: cat == .edition || cat == .language ? MusicAlbumEditionRules.badge(f, siblings: all) : .standard, category: cat, imageRef: img))
        }
        return out.sorted { ($0.category.rawValue, $0.facts.year ?? Int.max, $0.facts.title) < ($1.category.rawValue, $1.facts.year ?? Int.max, $1.facts.title) }
    }

    /// The badge of the opened album itself among its editions.
    static func ownFacts(_ r: MusicSoundtrackReader, entity: MusicEntityID) async -> MusicAlbumEditionFacts? {
        let dub = await r.edges(entity, .soundtrackOf, .outgoing, limit: 4).compactMap { $0.attributes.dubLanguage }.first
        return await editionFacts(r, entity, dub: dub)?.0
    }

    /// The tracks of one edition, for the comparison (titles in order, total duration).
    static func editionTracks(_ r: MusicSoundtrackReader, _ id: MusicEntityID) async -> (titles: [String], durationMs: Int64) {
        let edges = await trackEdges(r, id)
        let recs: [(Int, String, Int)?] = await r.boundedMap(edges) { e in
            guard let s = await r.entity(e.subject) else { return nil }
            return ((e.attributes.disc ?? 1) * 1000 + (e.attributes.position ?? e.order ?? 0), s.name, s.durationMs ?? 0)
        }
        let sorted = recs.compactMap { $0 }.sorted { $0.0 < $1.0 }
        return (sorted.map(\.1), Int64(sorted.map(\.2).reduce(0, +)))
    }

    static func info(_ r: MusicSoundtrackReader, entity: MusicEntityID, provider: MusicAlbum?) async -> MusicAlbumInfo {
        let family = await r.family(of: entity)
        var info = MusicAlbumInfo()
        func clean(_ s: String?) -> String? { let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        for m in family.members {
            guard let s = await r.entity(m) else { continue }
            info.description = info.description ?? clean(s.attrs["description"])
            info.label = info.label ?? clean(s.attrs["label"])
            info.catalogueNumber = info.catalogueNumber ?? clean(s.attrs["catalogNumber"] ?? s.attrs["catalogueNumber"])
            info.copyright = info.copyright ?? clean(s.attrs["copyright"])
            info.releaseDate = info.releaseDate ?? clean(s.attrs["releaseDate"])
            // The original year is the earliest of the opened release and the album or editions it belongs to, not the opened edition's own year.
            if let y = s.year, y > 0 { info.originalYear = min(info.originalYear ?? y, y) }
            if info.barcode == nil { info.barcode = clean(((try? await r.store.externalIDs(of: m)) ?? []).first { $0.scheme == .upc }?.value) }
            if let g = s.attrs["genres"] {
                for part in g.split(whereSeparator: { $0 == "|" || $0 == "," }) { let n = part.trimmingCharacters(in: .whitespaces); if !n.isEmpty, !info.genres.contains(n) { info.genres.append(n) } }
            }
            for e in await r.edges(m, .hasGenre, .outgoing, limit: 6) { if let n = await r.name(e.object), !info.genres.contains(n) { info.genres.append(n) } }
        }
        info.label = info.label ?? clean(provider?.label)
        info.releaseDate = info.releaseDate ?? clean(provider?.releaseDate)
        info.language = await r.facet(of: family.members, .inLanguage)?.name
        info.genres = Array(info.genres.prefix(6))
        return info
    }

    /// Composer and lyricist of each song, ONLY from edges on the recording itself. Album-level credits are never copied onto a song.
    static func trackMakers(_ r: MusicSoundtrackReader, recordings: [MusicEntityID]) async -> [MusicEntityID: MusicAlbumTrackMakers] {
        let ids = Array(recordings.prefix(MusicSoundtrackLimits.tracksForCredits))
        let rows: [(MusicEntityID, MusicAlbumTrackMakers)?] = await r.boundedMap(ids) { id in
            var m = MusicAlbumTrackMakers()
            for e in await r.edges(id, nil, .outgoing, limit: 40) where e.status != .conflicted && e.object.kind.isAgent {
                let role = e.role ?? MusicSoundtrackBuild.defaultRole(e.predicate)
                guard let name = await r.name(e.object) else { continue }
                switch role {
                case .composer, .musicDirector: if !m.composers.contains(name) { m.composers.append(name) }
                case .lyricist, .writer: if !m.lyricists.contains(name) { m.lyricists.append(name) }
                default: break
                }
            }
            return m.isEmpty ? nil : (id, m)
        }
        return Dictionary(rows.compactMap { $0 }, uniquingKeysWith: { a, _ in a })
    }

    /// The recordings of this album a person is credited on (any role), for the contributor sheet.
    static func tracks(of person: MusicEntityID, among recordings: [MusicEntityID], graph: any MusicGraphStoring) async -> Set<MusicEntityID> {
        let r = MusicSoundtrackReader(graph)
        let hits: [MusicEntityID?] = await r.boundedMap(recordings) { id in
            await r.edges(id, nil, .outgoing, limit: 40).contains { $0.object == person && $0.status != .conflicted } ? id : nil
        }
        return Set(hits.compactMap { $0 })
    }
}

// MARK: model

@MainActor @Observable
final class MusicAlbumExtrasModel {
    enum Phase { case idle, loading, loaded }
    let entity: MusicEntityID
    private(set) var versions: [MusicAlbumVersion] = []
    private(set) var versionsPhase = Phase.idle
    private(set) var own: MusicAlbumEditionFacts?
    private(set) var info = MusicAlbumInfo()
    private(set) var infoPhase = Phase.idle
    private(set) var makers: [MusicEntityID: MusicAlbumTrackMakers] = [:]
    private(set) var prefs = MusicAlbumPrefs.load()
    private(set) var concept: MusicEntityID?

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var makersFor: [MusicEntityID] = []

    init(entity: MusicEntityID) { self.entity = entity }

    private var graph: any MusicGraphStoring { MusicEntityRuntime.shared.store.graph }

    func stop() { tasks.values.forEach { $0.cancel() }; tasks = [:]; versionsPhase = .idle; infoPhase = .idle; makersFor = [] }

    /// Starts each part once; `force` re-reads (Refresh metadata).
    func loadVersions(force: Bool = false) {
        guard force || (tasks["versions"] == nil && versionsPhase == .idle) else { return }
        tasks["versions"]?.cancel()
        // A re-read of loaded data keeps `canChoose` true, so rating, tags and the preferred edition do not flicker disabled (and drop a save).
        if versionsPhase != .loaded { versionsPhase = .loading }
        let g = graph, id = entity
        tasks["versions"] = Task { [weak self] in
            let r = MusicSoundtrackReader(g)
            async let v = MusicAlbumReads.versions(r, entity: id)
            async let o = MusicAlbumReads.ownFacts(r, entity: id)
            async let c = MusicAlbumReads.albumConcept(r, id)
            let (versions, own, concept) = await (v, o, c)
            guard !Task.isCancelled, let self else { return }
            self.versions = versions; self.own = own; self.concept = concept; self.versionsPhase = .loaded
            self.migrateEntityKeyedChoices()
        }
    }

    func loadInfo(provider: MusicAlbum?, force: Bool = false) {
        guard force || (tasks["info"] == nil && infoPhase == .idle) else { return }
        tasks["info"]?.cancel()
        if infoPhase != .loaded { infoPhase = .loading }
        let g = graph, id = entity
        tasks["info"] = Task { [weak self] in
            let i = await MusicAlbumReads.info(MusicSoundtrackReader(g), entity: id, provider: provider)
            guard !Task.isCancelled, let self else { return }
            self.info = i; self.infoPhase = .loaded
        }
    }

    /// `force` reads again for the same songs: the graph changed (enrichment wrote composer and lyricist edges after the rows first appeared).
    func loadMakers(recordings: [MusicEntityID], force: Bool = false) {
        guard !recordings.isEmpty, force || recordings != makersFor else { return }
        makersFor = recordings
        tasks["makers"]?.cancel()
        let g = graph
        tasks["makers"] = Task { [weak self] in
            let m = await MusicAlbumReads.trackMakers(MusicSoundtrackReader(g), recordings: recordings)
            guard !Task.isCancelled, let self else { return }
            self.makers = m
        }
    }

    // MARK: choices

    var prefKey: String { (concept ?? entity).rawValue }
    var preferredEdition: MusicEntityID? { prefs.preferred[prefKey].flatMap(MusicEntityID.init(rawValue:)) }
    /// The album's concept is known once the versions have loaded; a choice made before that would be stored under the release's own id and lost.
    var canChoose: Bool { versionsPhase == .loaded }

    /// Re-reads the saved choices, applies one change and saves, so a second page open on the same album never overwrites it with an older copy.
    private func update(_ change: (inout MusicAlbumPrefs) -> Void) {
        var p = MusicAlbumPrefs.load()
        change(&p)
        p.save()
        prefs = p
    }

    /// Choices saved under the release's own id (before its album concept was known) move to the concept's id, unless the concept already has its own.
    private func migrateEntityKeyedChoices() {
        guard let concept, concept != entity else { return }
        let from = entity.rawValue, to = concept.rawValue
        let p = MusicAlbumPrefs.load()
        guard p.preferred[from] != nil || p.ratings[from] != nil || p.notes[from] != nil || p.tags[from] != nil else { return }
        update { p in
            if p.preferred[to] == nil, let v = p.preferred[from] { p.preferred[to] = v }
            if p.ratings[to] == nil, let v = p.ratings[from] { p.ratings[to] = v }
            if p.notes[to] == nil, let v = p.notes[from] { p.notes[to] = v }
            if p.tags[to] == nil, let v = p.tags[from] { p.tags[to] = v }
            p.preferred[from] = nil; p.ratings[from] = nil; p.notes[from] = nil; p.tags[from] = nil
        }
    }

    func setPreferred(_ id: MusicEntityID?) {
        guard canChoose else { return }
        let key = prefKey
        update { p in if let id { p.preferred[key] = id.rawValue } else { p.preferred[key] = nil } }
    }
    func setHidden(_ id: MusicEntityID, _ on: Bool) { update { $0.setHidden(id, on) } }

    var rating: Int? { prefs.ratings[prefKey] }
    var note: String { prefs.notes[prefKey] ?? "" }
    var tags: [String] { prefs.tags[prefKey] ?? [] }
    var hasPersonal: Bool { rating != nil || !note.isEmpty || !tags.isEmpty }

    func setRating(_ n: Int?) {
        guard canChoose else { return }
        let key = prefKey, v = n.flatMap(MusicAlbumPersonal.clampRating)
        update { p in p.ratings[key] = v }
    }
    func setNote(_ text: String) {
        guard canChoose else { return }
        let key = prefKey, t = MusicAlbumPersonal.clampNote(text)
        update { p in p.notes[key] = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : t }
    }
    func setTags(_ list: [String]) {
        guard canChoose else { return }
        let key = prefKey
        update { p in p.tags[key] = list.isEmpty ? nil : list }
    }
    var visibleVersions: [MusicAlbumVersion] { versions.filter { !prefs.isHidden($0.id) } }
    var hiddenVersions: [MusicAlbumVersion] { versions.filter { prefs.isHidden($0.id) } }
}
