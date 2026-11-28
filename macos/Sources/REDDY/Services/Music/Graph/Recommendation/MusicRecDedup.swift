import Foundation

/// Near-identical items fold into one (section 5.3). Remakes and dubs of the same film are NOT folded: they are different works, kept apart and flagged.
enum MusicRecDedup {
    /// The title with its version words taken off ("(Remix)", "- Karaoke Version", "(From "Awaara")"), folded to the Latin skeleton.
    static func versionNeutralTitle(_ title: String) -> String {
        var t = title
        let patterns = [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#, #"\s+(remix|karaoke|reprise|instrumental|unplugged|acoustic|live|remastered|version)\b.*$"#]
        for p in patterns { t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        let folded = MusicGraphText.latin(t.trimmingCharacters(in: .whitespaces))
        return folded.isEmpty ? MusicGraphText.latin(title) : folded
    }

    /// Keys that make two items "the same": any shared key puts them in one cluster.
    static func clusterKeys(id: MusicEntityID, snapshot s: MusicEntitySnapshot?, facets f: MusicRecFacets, view: MusicRecGraphView) -> Set<String> {
        var keys: Set<String> = ["id:" + id.rawValue]
        guard let s else { return keys }
        let neutral = versionNeutralTitle(s.name)
        switch id.kind {
        case .recording, .track, .work:
            for w in f.works.keys { keys.insert("work:" + w.rawValue) }
            if let p = f.primaryPerformer, !neutral.isEmpty { keys.insert("rec:\(neutral)|\(p.rawValue)") }
            else if let p = f.primaryPerformer { keys.insert("rec:|\(p.rawValue)") }
        case .album, .release:
            if let p = f.credits.filter({ !$0.value.inherited }).min(by: { $0.value.order != $1.value.order ? $0.value.order < $1.value.order : $0.key < $1.key })?.key {
                keys.insert("alb:\(MusicGraphText.latin(s.name))|\(p.rawValue)|\(s.year ?? 0)|\(s.lang.map(MusicRecLanguage.key) ?? "")")
            }
        case .film, .series:
            keys.insert("film:\(MusicGraphText.latin(s.name))|\(s.year ?? 0)|\(f.languages.filter { !$0.hasPrefix("id:") }.sorted().first ?? "")")
        default: break
        }
        if let img = s.imageRef, !img.isEmpty, !neutral.isEmpty { keys.insert("img:\(img)|\(neutral)") }
        return keys
    }

    /// Versions rank by how "original" they are: lower is better.
    static func originality(_ s: MusicEntitySnapshot) -> Int {
        guard let k = s.attrs["versionKind"].flatMap(MusicVersionKind.init(rawValue:)) else { return 1 }
        switch k { case .original: return 0; case .unknown: return 1; case .reRecording, .acoustic, .live: return 2; default: return 3 }
    }

    struct Entry {
        var candidate: MusicRecCandidate
        var keys: Set<String>
        var languages: Set<String>
    }

    /// Folds clusters to one representative each (original over remix or cover, a preferred language, then the better band and score) and drops the
    /// seed's own cluster unless `keepSeedVersions`. The representative keeps the best band and score found in its cluster, and `versionCount`.
    static func dedupe(_ entries: [Entry], seedKeys: Set<String>, preferred: Set<String>, keepSeedVersions: Bool) -> [MusicRecCandidate] {
        var parent = Array(0..<entries.count)
        func find(_ i: Int) -> Int { var r = i; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        var owner: [String: Int] = [:]
        for (i, e) in entries.enumerated() {
            for k in e.keys where !k.hasPrefix("id:") {
                if let j = owner[k] { parent[find(i)] = find(j) } else { owner[k] = i }
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in entries.indices { clusters[find(i), default: []].append(i) }
        let seedShared = seedKeys.filter { !$0.hasPrefix("id:") }
        var out: [MusicRecCandidate] = []
        for (_, members) in clusters {
            let isSeedCluster = members.contains { !entries[$0].keys.isDisjoint(with: seedShared) }
            let group = members.map { entries[$0] }
            if isSeedCluster && !keepSeedVersions { continue }
            func rank(_ e: Entry) -> (Int, Int, Int, Double, String) {
                (originality(e.candidate.snapshot), e.languages.isDisjoint(with: preferred) ? 1 : 0, e.candidate.band.rawValue, -e.candidate.score, e.candidate.id.rawValue)
            }
            var best = group.min { a, b in rank(a) < rank(b) }!.candidate
            let strongest = group.map(\.candidate).min { a, b in a.band != b.band ? a.band < b.band : a.score > b.score }!
            if strongest.band < best.band || (strongest.band == best.band && strongest.score > best.score) {
                best.band = strongest.band; best.score = strongest.score; best.explanation = strongest.explanation; best.confidence = strongest.confidence
                best.otherReasons = strongest.otherReasons
            }
            best.versionCount = group.count
            best.flags.formUnion(group.flatMap(\.candidate.flags))
            out.append(best)
        }
        return out
    }

    /// Items that share a title with another item (or the seed) but are a different year (remake) or language (dub) stay separate and get a flag.
    static func flagRemakes(_ items: [MusicRecCandidate], seed: MusicEntitySnapshot?) -> [MusicRecCandidate] {
        func family(_ k: MusicEntityKind) -> String? {
            switch k { case .film, .series: "f"; case .album, .release: "a"; default: nil }
        }
        func titleKey(_ k: MusicEntityKind, _ name: String) -> String? {
            guard let f = family(k) else { return nil }
            let t = MusicGraphText.latin(name)
            return t.isEmpty ? nil : f + "|" + t
        }
        var byTitle: [String: [MusicEntitySnapshot]] = [:]
        if let seed, let k = titleKey(seed.kind, seed.name) { byTitle[k, default: []].append(seed) }
        for c in items { if let k = titleKey(c.kind, c.snapshot.name) { byTitle[k, default: []].append(c.snapshot) } }
        var out = items
        for i in out.indices {
            guard let k = titleKey(out[i].kind, out[i].snapshot.name), let group = byTitle[k], group.count > 1 else { continue }
            let me = out[i].snapshot
            let others = group.filter { $0.id != me.id }
            if others.contains(where: { $0.year != nil && me.year != nil && $0.year != me.year }) { out[i].flags.insert(.remake) }
            else if others.contains(where: { $0.lang != nil && me.lang != nil && MusicRecLanguage.key($0.lang!) != MusicRecLanguage.key(me.lang!) }) { out[i].flags.insert(.dub) }
        }
        return out
    }
}

extension MusicEntityKind {
    var isFilmLike: Bool { self == .film || self == .series }
}
