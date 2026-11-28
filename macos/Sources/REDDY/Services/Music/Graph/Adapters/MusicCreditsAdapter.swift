import Foundation

/// Credits a provider returned, as graph drafts and edge claims (section 3.7 of the graph design). Pure: no store, no network, no clock but the one passed in.
///
/// Rules: a claim exists only for a credit the provider returned (nothing is inferred from a name or a role); confidence follows how specific the credit
/// is (song 0.9, album 0.8, film 0.6, tagged "film credit"); a person is never merged by name: a credit with a provider id is aliased to that id, a credit with
/// no id gets its own role-qualified provisional entity for the resolver to link later (two signals, never a name alone); a hyphenated duo such as
/// "Shankar-Jaikishan" is a group CANDIDATE at low confidence, with member edges only when a source listed the members; a soundtrack-to-film link is
/// only ever `inferred`, with the signals that suggested it as evidence.
struct MusicCreditsBatch: Sendable {
    /// Unique by `derivedID`; the order is the order they first appeared.
    var drafts: [MusicEntityDraft] = []
    /// Edge ids are the drafts' derived ids; `MusicCreditsAdapter.commit` rewrites them to the ids the store settles on.
    var claims: [MusicEdgeClaim] = []
    var isEmpty: Bool { claims.isEmpty && drafts.isEmpty }
}

enum MusicCreditsAdapter {
    /// Provider credits are cached for 14 days (section 3.8) and re-read when the item is seen again.
    static let providerTTL: TimeInterval = 14 * 86_400
    static let filmCreditTag = "film credit"

    // MARK: confidence

    static func confidence(for level: MusicCreditLevel) -> Float {
        switch level { case .track: 0.9; case .album: 0.8; case .film: 0.6 }
    }
    static let groupCandidateConfidence: Float = 0.45

    // MARK: entry points

    static func batch(track t: MusicTrack, now: Date = Date()) -> MusicCreditsBatch {
        var b = Builder(providerID: t.providerID, sourceRef: t.uid, now: now)
        b.addTrack(t)
        return b.batch
    }

    static func batch(album a: MusicAlbum, tracks: [MusicTrack], now: Date = Date()) -> MusicCreditsBatch {
        var b = Builder(providerID: a.providerID, sourceRef: a.uid, now: now)
        let albumCredits = a.credits ?? []
        let releaseID = b.draft(MusicGraphAdapters.albumDraft(a))
        b.addPlan(MusicGraphAdapters.plan(for: a), primaryID: releaseID, skipPerformers: !albumCredits.isEmpty)
        // One soundtrack decision for the album: its own title and genre, and whether it or its songs carried a cast credit.
        let hasCast = (albumCredits + tracks.flatMap { $0.credits ?? [] }).contains { $0.role == .starring }
        let film = b.soundtrack(release: releaseID, title: a.title, albumType: a.albumType, hints: a.hints ?? tracks.lazy.compactMap { $0.hints }.first,
                                hasStarring: hasCast, scope: a.uid)
        b.addCredits(albumCredits, subjects: .init(track: releaseID, album: releaseID, film: film), hints: a.hints)
        for t in tracks { b.addTrack(t, release: releaseID, albumFilm: film, scope: a.uid) }
        return b.batch
    }

    /// Writes a batch: drafts in one transaction, then every claim with the ids the store settled on. Throws what the store throws; the caller drops it.
    static func commit(_ batch: MusicCreditsBatch, to store: any MusicGraphStoring) async throws {
        guard !batch.isEmpty else { return }
        let results = try await store.upsert(batch.drafts)
        var map: [MusicEntityID: MusicEntityID] = [:]
        for (d, r) in zip(batch.drafts, results) { map[d.derivedID] = r.id }
        var claims: [MusicEdgeClaim] = []
        for c in batch.claims {
            var e = c.edge
            guard let s = map[e.subject], let o = map[e.object], s != o, e.predicate.accepts(subject: s.kind, object: o.kind) else { continue }
            e.subject = s; e.object = o
            claims.append(MusicEdgeClaim(e, c.provenance))
        }
        if !claims.isEmpty { _ = try await store.addEdges(claims) }
    }

    // MARK: version typing

    struct VersionHint: Equatable, Sendable { var kind: MusicVersionKind; var evidence: [String] }

    /// What kind of version a title (or the provider's own flag) says this is. Nil when nothing says so: a recording is never assumed to be the original here.
    static func versionHint(title: String, hints: MusicProviderHints? = nil) -> VersionHint? {
        switch hints?.version?.lowercased() {
        case "remix": return VersionHint(kind: .remix, evidence: ["provider-flag"])
        case "cover": return VersionHint(kind: .cover, evidence: ["provider-flag"])
        default: break
        }
        let t = title.lowercased()
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\bkaraoke\b"#) { return VersionHint(kind: .karaoke, evidence: ["title-karaoke"]) }
        if has(#"\bre-?mix(ed)?\b"#) { return VersionHint(kind: .remix, evidence: ["title-remix"]) }
        if has(#"\blive (at|from|in|on|version)\b|[\(\[\-–]\s*live\b"#) { return VersionHint(kind: .live, evidence: ["title-live"]) }
        if has(#"\breprise\b"#) { return VersionHint(kind: .reprise, evidence: ["title-reprise"]) }
        if has(#"\bre-?record(ed|ing)\b|\bre-?created\b"#) { return VersionHint(kind: .reRecording, evidence: ["title-re-recorded"]) }
        if has(#"\bunplugged\b|\bacoustic\b"#) { return VersionHint(kind: .acoustic, evidence: ["title-unplugged"]) }
        if has(#"[\(\[\-–]\s*cover\b|\bcover version\b|\bcovered by\b|\boriginally performed by\b"#) { return VersionHint(kind: .cover, evidence: ["title-cover"]) }
        if has(#"\binstrumental\b"#) { return VersionHint(kind: .instrumental, evidence: ["title-instrumental"]) }
        return nil
    }

    // MARK: soundtrack hint

    struct SoundtrackHint: Equatable, Sendable { var film: String; var evidence: [String]; var confidence: Float }

    /// An INFERRED soundtrack-of-film suggestion from an album's own wording. Never `stated`, so the store can never make it `verified`.
    static func soundtrackHint(albumTitle: String, albumType: String? = nil, hints: MusicProviderHints? = nil, hasStarring: Bool = false) -> SoundtrackHint? {
        let lower = albumTitle.lowercased()
        var evidence: [String] = []
        var score: Float = 0.4
        func mark(_ token: String, _ w: Float) { evidence.append(token); score += w }
        let titleSoundtrack = lower.range(of: #"\b(soundtrack|ost|original score|motion picture)\b"#, options: .regularExpression) != nil
        let from = MusicGraphAdapters.filmHint(inTitle: albumTitle)
        if titleSoundtrack { mark("title-soundtrack", 0.2) }
        if from != nil { mark("title-from", 0.15) }
        if (hints?.genre ?? "").lowercased().contains("soundtrack") { mark("genre-soundtrack", 0.15) }
        if (albumType ?? "").lowercased().contains("soundtrack") { mark("album-type", 0.1) }
        if hasStarring { mark("starring-credits", 0.1) }
        guard !evidence.isEmpty else { return nil }
        let name = (hints?.film).flatMap(MusicCreditCollector.cleanName) ?? from ?? filmTitle(fromAlbumTitle: albumTitle)
        guard let film = name, !film.isEmpty else { return nil }
        if hints?.film != nil { evidence.append("provider-film") }
        return SoundtrackHint(film: film, evidence: evidence, confidence: min(0.75, score))
    }

    /// "Jailer 2" from "Jailer 2 (Original Motion Picture Soundtrack)", "Awara" from "Awara (The Bollywood Soundtrack)", "Squid Game" from "Squid Game OST".
    static func filmTitle(fromAlbumTitle title: String) -> String? {
        var t = title
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*\b(soundtrack|ost|original score|motion picture)\b[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s*[-–:]?\s*\b(original (motion picture )?soundtrack|ost|original score)\b\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s*[\(\[]\s*from\s+[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        let out = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    // MARK: duos

    /// "Shankar-Jaikishan", "Shankar – Jaikishan", "Vishal-Shekhar": two capitalised names joined by a hyphen or dash, nothing else. A candidate only.
    static func isDuoName(_ name: String) -> Bool {
        name.range(of: #"^\p{Lu}[\p{L}'.]{2,}\s*[-–—]\s*\p{Lu}[\p{L}'.]{2,}$"#, options: .regularExpression) != nil
    }

    // MARK: role mapping

    struct Mapping: Equatable, Sendable { var predicate: MusicPredicate; var role: MusicRole }

    static func mapping(for credit: MusicCredit) -> Mapping? {
        switch credit.role {
        case .primary, .albumArtist: Mapping(predicate: .performedBy, role: .performer)
        case .performer: Mapping(predicate: .performedBy, role: credit.instrument == nil ? .performer : .instrumentalist)
        case .singer: Mapping(predicate: .performedBy, role: .singer)
        case .featured: Mapping(predicate: .performedBy, role: .featured)
        case .conductor: Mapping(predicate: .performedBy, role: .conductor)
        case .remixer: Mapping(predicate: .performedBy, role: .remixer)
        case .music: Mapping(predicate: .musicDirectedBy, role: .musicDirector)
        case .composer: Mapping(predicate: .composedBy, role: .composer)
        case .arranger: Mapping(predicate: .composedBy, role: .arranger)
        case .lyricist: Mapping(predicate: .writtenBy, role: .lyricist)
        case .writer: Mapping(predicate: .writtenBy, role: .writer)
        case .producer: Mapping(predicate: .producedBy, role: .producer)
        case .starring: Mapping(predicate: .hasCast, role: .actor)
        case .other: nil
        }
    }

    static func edgeLevel(_ l: MusicCreditLevel) -> CreditLevel {
        switch l { case .track: .song; case .album: .album; case .film: .film }
    }

    // MARK: builder

    struct Subjects { var track: MusicEntityID; var album: MusicEntityID; var film: MusicEntityID? }

    struct Builder {
        let providerID: String
        let sourceRef: String
        let now: Date
        private(set) var batch = MusicCreditsBatch()
        private var known = Set<MusicEntityID>()
        private var edgeKeys = Set<MusicEdgeKey>()

        init(providerID: String, sourceRef: String, now: Date) { self.providerID = providerID; self.sourceRef = sourceRef; self.now = now }

        @discardableResult
        mutating func draft(_ d: MusicEntityDraft) -> MusicEntityID {
            let id = d.derivedID
            if known.insert(id).inserted { batch.drafts.append(d) }
            return id
        }

        func provenance(score: Float, evidence: [String]) -> MusicProvenance {
            MusicProvenance(source: MusicSourceID(providerID), sourceRef: sourceRef, retrievedAt: now, expiresAt: now.addingTimeInterval(providerTTL),
                            license: .providerCache, score: score, evidence: evidence)
        }

        mutating func claim(_ e: MusicEdge, score: Float, evidence: [String]) {
            guard e.subject != e.object, e.predicate.accepts(subject: e.subject.kind, object: e.object.kind), edgeKeys.insert(e.key).inserted else { return }
            var edge = e; edge.confidence = score
            batch.claims.append(MusicEdgeClaim(edge, provenance(score: score, evidence: evidence)))
        }

        /// The plan G1's adapter builds from the item's own fields (artists, album placement) as claims. Performers are skipped when credits cover them.
        mutating func addPlan(_ plan: MusicMintPlan, primaryID: MusicEntityID, skipPerformers: Bool) {
            for (i, link) in plan.links.enumerated() {
                if skipPerformers && link.predicate == .performedBy { continue }
                let other = draft(link.draft)
                let (s, o) = link.direction == .incoming ? (other, primaryID) : (primaryID, other)
                var edge = MusicEdge(subject: s, predicate: link.predicate, object: o, qualifier: link.role?.rawValue ?? "", attributes: link.attributes,
                                     creditLevel: link.creditLevel, order: link.order ?? i)
                edge.confidence = link.score ?? plan.defaultScore
                claim(edge, score: edge.confidence, evidence: link.evidence)
            }
        }

        /// A song: the recording, its placement, its credits, and (when no album decided it already) the soundtrack hint of its album.
        mutating func addTrack(_ t: MusicTrack, release albumRelease: MusicEntityID? = nil, albumFilm: MusicEntityID? = nil, scope albumScope: String? = nil) {
            let plan = MusicGraphAdapters.plan(for: t)
            var primary = plan.primary
            let hint = MusicCreditsAdapter.versionHint(title: t.title, hints: t.hints)
            if let hint { primary.attrs["versionKind"] = hint.kind.rawValue; primary.attrs["versionEvidence"] = hint.evidence.joined(separator: ",") }
            if let w = t.hints?.work { primary.attrs["work"] = w }
            if let l = t.hints?.language { primary.attrs["languageHint"] = l }
            let recording = draft(primary)
            let credits = t.credits ?? []
            addPlan(plan, primaryID: recording, skipPerformers: !credits.isEmpty)
            let release = albumRelease ?? t.album.map { draft(MusicGraphAdapters.albumDraft($0, providerID: t.providerID)) }
            let scope = albumScope ?? t.album.flatMap { $0.id.isEmpty ? nil : t.providerID + ":" + $0.id } ?? t.uid
            var film = albumFilm
            if film == nil, albumRelease == nil, let ref = t.album, let rel = release {
                film = soundtrack(release: rel, title: ref.title, albumType: ref.albumType, hints: t.hints, hasStarring: credits.contains { $0.role == .starring }, scope: scope)
            }
            // "(From "Film")" in the title: the recording is featured in that film, weakly.
            if let name = MusicGraphAdapters.filmHint(inTitle: t.title) {
                let f = filmDraft(name: name, hints: t.hints, scope: scope)
                claim(MusicEdge(subject: recording, predicate: .featuredIn, object: f, creditLevel: .song), score: 0.4, evidence: ["title-from"])
                if film == nil { film = f }
            }
            addCredits(credits, subjects: .init(track: recording, album: release ?? recording, film: film), hints: t.hints)
        }

        // MARK: credits

        mutating func addCredits(_ credits: [MusicCredit], subjects: Subjects, hints: MusicProviderHints?) {
            for (i, c) in credits.enumerated() {
                guard let m = MusicCreditsAdapter.mapping(for: c) else { continue }
                let subject: MusicEntityID
                switch c.level {
                case .track: subject = subjects.track
                case .album: subject = subjects.album
                case .film: guard let f = subjects.film else { continue }; subject = f
                }
                let personID = person(c)
                var attrs = EdgeAttributes()
                attrs.creditOrder = i
                attrs.instrument = c.instrument; attrs.characterName = c.character
                var score = MusicCreditsAdapter.confidence(for: c.level)
                var evidence = ["provider-credit", "role:" + c.role.rawValue]
                if c.level == .film { evidence.append(MusicCreditsAdapter.filmCreditTag) }
                if personID.kind == .group, c.members?.isEmpty ?? true { score = min(score, MusicCreditsAdapter.groupCandidateConfidence); evidence.append("group-candidate") }
                claim(MusicEdge(subject: subject, predicate: m.predicate, object: personID, qualifier: m.role.rawValue, attributes: attrs,
                                creditLevel: MusicCreditsAdapter.edgeLevel(c.level), order: i), score: score, evidence: evidence)
                for member in c.members ?? [] {
                    let mid = person(member)
                    claim(MusicEdge(subject: mid, predicate: .memberOf, object: personID, creditLevel: .unknown), score: 0.9, evidence: ["members-listed"])
                }
            }
        }

        /// A role-qualified person (or group) draft. Never merged by name: a provider id is the alias; with none, the draft is keyed by name AND role.
        mutating func person(_ c: MusicCredit) -> MusicEntityID {
            let hintProvider = providerID
            let hasID = !(c.providerArtistID ?? "").isEmpty
            // With a provider id the shape of the name decides (so one id is one kind everywhere); with none, only roles duos are credited in.
            let isGroup = !(c.members ?? []).isEmpty || (MusicCreditsAdapter.isDuoName(c.name) && (hasID || Self.duoRoles.contains(c.role)))
            let kind: MusicEntityKind = isGroup ? .group : .person
            var ids: [ExternalID] = []
            if let pid = c.providerArtistID, !pid.isEmpty { ids = [ExternalID(.provider, hintProvider + ":" + pid)] }
            else { ids = [ExternalID(.canon, kind.slug + "|" + MusicGraphText.latin(c.name) + "|" + c.role.rawValue)] }
            var d = MusicEntityDraft(kind: kind, name: c.name, attrs: [:], externalIDs: ids, aliases: [NameAlias(c.name, isPrimary: true, source: hintProvider)], provisional: true)
            if isGroup && (c.members ?? []).isEmpty { d.attrs["groupCandidate"] = "1" }
            if c.providerArtistID == nil { d.attrs["credited"] = "name only" }
            for m in c.members ?? [] { _ = draft(MusicEntityDraft(kind: .person, name: m.name, externalIDs: m.providerArtistID.map { [ExternalID(.provider, hintProvider + ":" + $0)] } ?? [ExternalID(.canon, "person|" + MusicGraphText.latin(m.name) + "|" + MusicRole.performer.rawValue)], provisional: true)) }
            return draft(d)
        }

        static let duoRoles: Set<MusicCreditRole> = [.primary, .music, .composer, .arranger, .performer]

        // MARK: film

        /// A provisional film draft. Keyed by title, year and language when the provider gave a year or language; else by the album or song it came from,
        /// so two films of one title never collapse before a source has said they are the same.
        mutating func filmDraft(name: String, hints: MusicProviderHints?, scope: String) -> MusicEntityID {
            let key: ExternalID
            if hints?.year != nil || hints?.language != nil {
                key = ExternalID(.canon, "film|" + MusicGraphText.latin(name) + "|" + (hints?.year.map(String.init) ?? "") + "|" + (hints?.language ?? ""))
            } else {
                key = ExternalID(.provider, scope + "#film|" + MusicGraphText.latin(name))
            }
            var d = MusicEntityDraft(kind: .film, name: name, lang: nil, externalIDs: [key], aliases: [NameAlias(name, isPrimary: true, source: providerID)], provisional: true)
            d.attrs["filmHint"] = "1"
            if let y = hints?.year { d.attrs["yearHint"] = String(y) }
            if let l = hints?.language { d.attrs["languageHint"] = l }
            return draft(d)
        }

        /// The inferred soundtrack edge for a release, when its own wording or cast credits suggest a film. Returns the film's id.
        @discardableResult
        mutating func soundtrack(release: MusicEntityID, title: String, albumType: String?, hints: MusicProviderHints?, hasStarring: Bool, scope: String) -> MusicEntityID? {
            guard let s = MusicCreditsAdapter.soundtrackHint(albumTitle: title, albumType: albumType, hints: hints, hasStarring: hasStarring) else { return nil }
            let film = filmDraft(name: s.film, hints: hints, scope: scope)
            guard release.kind == .release || release.kind == .album else { return film }
            claim(MusicEdge(subject: release, predicate: .soundtrackOf, object: film, creditLevel: .film), score: s.confidence, evidence: s.evidence)
            return film
        }
    }
}
