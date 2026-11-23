import Testing
import Foundation
@testable import REDDY

/// Persona evaluation harness (see tools/personas/README.md). Runs the matching, search, Smart Mix and guide-mapping engines offline over the synthetic persona corpus and writes metrics as JSON.
/// Opt in with STREAMSETU_PERSONAS=<dir with the generated personas>; STREAMSETU_PERSONA_OUT=<metrics.json> (default: <dir>/metrics.json). Nothing here touches the network or any user data.
enum PersonaCorpus {
    struct Item: Decodable { var id: String; var kind: String; var raw: String; var year: Int?; var gold: Int?; var lang: String?; var category: String; var noise: [String]; var genre: String; var rating: String
        var poster: Bool; var restricted: Bool; var addedDays: Int; var quality: Int }
    struct Chan: Decodable { var name: String; var tvg: String?; var country: String?; var gold: String?; var noise: [String] }
    struct Persona: Decodable { var persona: String; var kids: Bool; var items: [Item]; var channels: [Chan] }
    struct IndexItem: Decodable { var id: Int; var kind: String; var title: String; var original: String; var year: Int?; var pop: Double; var lang: String }
    struct GuideItem: Decodable { var id: String; var name: String; var country: String?; var language: String? }
    static let langName: [String: String] = ["en": "English", "hi": "Hindi", "te": "Telugu", "ta": "Tamil", "ml": "Malayalam", "kn": "Kannada", "bn": "Bengali", "mr": "Marathi", "pa": "Punjabi", "ur": "Urdu", "ko": "Korean", "ja": "Japanese", "zh": "Chinese", "tr": "Turkish", "ar": "Arabic", "es": "Spanish", "pt": "Portuguese", "fr": "French", "de": "German", "it": "Italian", "ru": "Russian", "id": "Indonesian", "th": "Thai"]
    static var dir: URL? { ProcessInfo.processInfo.environment["STREAMSETU_PERSONAS"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static func load<T: Decodable>(_ name: String, _ t: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: Data(contentsOf: dir!.appendingPathComponent(name + ".json"))) }
    static let personaNames = ["english-small", "telugu-hindi", "south-indian", "anime-fan", "asian-drama", "turkish-arabic", "latin-america", "european", "kids-household", "series-only", "movies-only", "new-user", "bare-library", "heavy-duplicates", "large-66k", "huge-200k", "sports-live-only"]
}

/// What TMDB's search endpoint does, served from the cached public corpus: every query word must be a word of the title (or original title), with a one-letter slip tolerated on long words; popular first.
final class PersonaTMDB: @unchecked Sendable {
    var items: [PersonaCorpus.IndexItem]
    var post: [String: [Int]] = [:]       // token -> item index
    var vocab: [String] = []
    private let callLock = NSLock(); private var n = 0
    var calls: Int { callLock.withLock { n } }
    init(_ items: [PersonaCorpus.IndexItem]) {
        self.items = items
        for (i, it) in items.enumerated() { for t in Set(tokens(it.title) + tokens(it.original)) { post[t, default: []].append(i) } }
        vocab = Array(post.keys)
    }
    func tokens(_ s: String) -> [String] { ArtworkMatchDecision.canon(s).split(separator: " ").map(String.init) }
    func search(_ q: String, series: Bool, year: Int?) -> [ArtworkMatchDecision.Candidate] {
        let kind = series ? "series" : "movie"
        let qt = tokens(q); guard !qt.isEmpty else { return [] }
        var sets: [Set<Int>] = []
        for t in qt {
            var s = Set(post[t] ?? [])
            if s.isEmpty, t.count >= 6 { for v in vocab where abs(v.count - t.count) <= 1 && v.first == t.first && ArtworkMatchDecision.levenshteinRatio(v, t) >= 0.83 { s.formUnion(post[v] ?? []) } }
            sets.append(s)
        }
        var hit = sets[0]; for s in sets.dropFirst() { hit.formIntersection(s) }
        let canonQ = qt.joined(separator: " ")
        var list = hit.map { items[$0] }.filter { $0.kind == kind && (year == nil || $0.year == year) }
        list.sort { a, b in
            let ea = ArtworkMatchDecision.canon(a.title) == canonQ, eb = ArtworkMatchDecision.canon(b.title) == canonQ
            if ea != eb { return ea }
            return a.pop != b.pop ? a.pop > b.pop : a.id < b.id
        }
        return list.prefix(20).map { .init(id: $0.id, title: $0.title, originalTitle: $0.original, year: $0.year, popularity: $0.pop, originalLanguage: $0.lang) }
    }
}

extension PersonaTMDB {
    /// The reply TMDB would give to a /3/search/{movie,tv} request, in TMDB's JSON shape, so the real MetadataMatchService.lookup runs unchanged over it.
    func reply(_ req: URLRequest) -> Data {
        callLock.withLock { n += 1 }
        guard let url = req.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return Data("{\"results\":[]}".utf8) }
        let series = c.path.hasSuffix("/search/tv")
        // Details by id (the alias index and provider ids fetch this way): the same item in the details shape.
        if !c.path.contains("/search/"), let id = Int(c.path.split(separator: "/").last ?? ""), let tvPath = Optional(c.path.contains("/3/tv/")), let it = items.first(where: { $0.id == id && ($0.kind == "series") == tvPath }) {
            var d: [String: Any] = ["id": it.id, tvPath ? "name" : "title": it.title, tvPath ? "original_name" : "original_title": it.original, "popularity": it.pop, "original_language": it.lang ?? "", "poster_path": "/p.jpg"]
            if let y = it.year { d[tvPath ? "first_air_date" : "release_date"] = "\(y)-01-01" }
            return (try? JSONSerialization.data(withJSONObject: d)) ?? Data()
        }
        func q(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        let found = search(q("query") ?? "", series: series, year: (q("year") ?? q("first_air_date_year")).flatMap(Int.init))
        let rows: [[String: Any]] = found.map { r in
            var d: [String: Any] = ["id": r.id, series ? "name" : "title": r.title ?? "", series ? "original_name" : "original_title": r.originalTitle ?? "", "popularity": r.popularity, "original_language": r.originalLanguage ?? ""]
            if let y = r.year { d[series ? "first_air_date" : "release_date"] = "\(y)-01-01" }
            return d
        }
        return (try? JSONSerialization.data(withJSONObject: ["results": rows])) ?? Data()
    }
}

struct Tally { var correct = 0, wrong = 0, miss = 0, spurious = 0 }

@Suite("Persona evaluation (opt in)") struct PersonaEvalTests {
    @Test(.enabled(if: PersonaCorpus.dir != nil)) func runAll() async throws {
        var metrics: [String: [String: [String: Double]]] = [:]       // persona -> engine -> metric -> value
        func put(_ p: String, _ e: String, _ k: String, _ v: Double) { metrics[p, default: [:]][e, default: [:]][k] = (v * 10000).rounded() / 10000 }
        let only = ProcessInfo.processInfo.environment["STREAMSETU_PERSONA_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let tmdb = PersonaTMDB(try PersonaCorpus.load("tmdb-index", [String: [PersonaCorpus.IndexItem]].self)["items"]!)
        let guide = try PersonaCorpus.load("guide", [String: [PersonaCorpus.GuideItem]].self)["guide"]!
        var byNoise: [String: Tally] = [:], byLang: [String: Tally] = [:]
        let engines = Set(ProcessInfo.processInfo.environment["STREAMSETU_PERSONA_ENGINES"]?.split(separator: ",").map(String.init) ?? ["match", "search", "mix", "guide"])
        for name in PersonaCorpus.personaNames where only == nil || only!.contains(name) {
            let p = try PersonaCorpus.load(name, PersonaCorpus.Persona.self)
            if engines.contains("match") { try await Self.matcher(p, tmdb, &byNoise, &byLang, put) }
            if engines.contains("search") { Self.search(p, put) }
            if engines.contains("mix") { Self.mix(p, put) }
            if engines.contains("guide") { Self.guide(p, guide, put) }
        }
        for (k, t) in byNoise { put("ALL", "match.noise", k + ".correct", Double(t.correct)); put("ALL", "match.noise", k + ".wrong", Double(t.wrong)); put("ALL", "match.noise", k + ".miss", Double(t.miss)) }
        for (k, t) in byLang { put("ALL", "match.lang", k + ".correct", Double(t.correct)); put("ALL", "match.lang", k + ".wrong", Double(t.wrong)); put("ALL", "match.lang", k + ".miss", Double(t.miss)) }
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STREAMSETU_PERSONA_OUT"] ?? PersonaCorpus.dir!.appendingPathComponent("metrics.json").path)
        try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys, .prettyPrinted]).write(to: out)
    }

    // MARK: matching
    static func matcher(_ p: PersonaCorpus.Persona, _ tmdb: PersonaTMDB, _ byNoise: inout [String: Tally], _ byLang: inout [String: Tally], _ put: (String, String, String, Double) -> Void) async throws {
        // The real service, with its transport replaced by the cached corpus: nothing is mirrored, so the harness cannot drift from the app.
        let creds = InMemoryCredentialStore()
        try creds.save(Credentials(username: "tmdb", password: "0123456789abcdef0123456789abcdef"), ref: MetadataMatchService.keyRef)
        let svc = MetadataMatchService(db: try TestSupport.makeDB(), credentials: creds, pause: 0) { tmdb.reply($0) }
        // Switches for the ablations: STREAMSETU_ABLATE=alias,phonetic,cache (each switches that part off).
        let off = Set((ProcessInfo.processInfo.environment["STREAMSETU_ABLATE"] ?? "").split(separator: ",").map(String.init))
        if let path = ProcessInfo.processInfo.environment["STREAMSETU_ALIASES"], !off.contains("alias"), let idx = AliasIndex(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) { svc.aliasIndex = idx }
        let on = Set((ProcessInfo.processInfo.environment["STREAMSETU_ENABLE"] ?? "").split(separator: ",").map(String.init)); svc.aliasExactEnabled = on.contains("exact"); svc.aliasPhoneticEnabled = on.contains("phonetic")
        if let t = ProcessInfo.processInfo.environment["STREAMSETU_TIERS"] { svc.extraTiers = Set(t.split(separator: ",").map(String.init)) }
        svc.seriesCacheEnabled = !off.contains("cache")
        var rows = p.items.filter { $0.gold != nil || $0.noise.contains("collection") || $0.noise.contains("non-title") }
        // Large libraries are sampled evenly (the engine is per title, so a sample measures it).
        if rows.count > 1500 { let step = Double(rows.count) / 1500; rows = (0..<1500).map { rows[Int(Double($0) * step)] } }
        var t = Tally()
        for it in rows {
            let series = it.kind == "series"
            let tag = IdentityDerive.language(title: it.raw, folder: it.category) ?? ""
            let got = try await svc.lookup(MetadataMatchService.Candidate(id: it.id, isSeries: series, title: it.raw, year: it.year, languageTag: tag))?.tmdbID
            var outcome = 0                                        // 0 correct, 1 wrong, 2 miss, 3 spurious
            if let g = it.gold { outcome = got == g ? 0 : (got == nil ? 2 : 1) } else { outcome = got == nil ? 0 : 3 }
            if it.gold != nil {
                for k in Set(it.noise.map { $0.hasPrefix("year-") ? "year-mark" : $0.hasPrefix("lang-") ? "lang-tag" : $0 } + (it.noise.isEmpty ? ["clean"] : [])) {
                    var x = byNoise[k] ?? Tally(); apply(&x, outcome); byNoise[k] = x
                }
                var l = byLang[it.lang ?? "?"] ?? Tally(); apply(&l, outcome); byLang[it.lang ?? "?"] = l
            }
            apply(&t, outcome)
            if let d = rowsDir { dump(d, "rows-\(p.persona)", "\(it.id)\t\(p.persona)\t\(outcome)\t\(stableHash(it.id) % 5 == 0 ? "holdout" : "tune")\t\(it.noise.isEmpty ? "clean" : it.noise.joined(separator: ","))\t\(it.lang ?? "")\t\(it.gold ?? 0)\t\(series ? "tv" : "movie")") }
            if outcome != 0, let d = dumpDir { dump(d, "match", "\(p.persona)\t\(outcome)\t\(it.noise.joined(separator: ","))\t\(it.lang ?? "")\t\(it.raw)\t\(it.gold ?? 0)\t\(got ?? 0)") }
        }
        let gold = Double(t.correct + t.wrong + t.miss)
        put(p.persona, "match", "requests", Double(tmdb.calls)); put(p.persona, "match", "n", Double(rows.count)); put(p.persona, "match", "precision", Double(t.correct) / max(1, Double(t.correct + t.wrong + t.spurious)))
        put(p.persona, "match", "recall", Double(t.correct) / max(1, gold)); put(p.persona, "match", "wrongRate", Double(t.wrong + t.spurious) / max(1, Double(rows.count)))
    }
    /// Optional: STREAMSETU_PERSONA_DUMP=<dir> appends every miss / wrong match as a tab-separated line, to look at what the engines get wrong.
    static var dumpDir: URL? { ProcessInfo.processInfo.environment["STREAMSETU_PERSONA_DUMP"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    /// STREAMSETU_PERSONA_ROWS=<dir>: one line per evaluated row (id, persona, outcome 0 right 1 wrong 2 miss 3 spurious, holdout or tune, noise, language), for the report script.
    static var rowsDir: URL? { ProcessInfo.processInfo.environment["STREAMSETU_PERSONA_ROWS"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static func stableHash(_ s: String) -> UInt64 { var h: UInt64 = 0xcbf29ce484222325; for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }; return h }
    static func dump(_ dir: URL, _ name: String, _ line: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(name + ".tsv")
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() } else { try? Data((line + "\n").utf8).write(to: f) }
    }
    static func apply(_ t: inout Tally, _ o: Int) { switch o { case 0: t.correct += 1; case 1: t.wrong += 1; case 2: t.miss += 1; default: t.spurious += 1 } }

    // MARK: search
    static func search(_ p: PersonaCorpus.Persona, _ put: (String, String, String, Double) -> Void) {
        guard p.items.count > 100 else { return }
        var rng = SplitMix64(seed: 99)
        func u(_ n: Int) -> Int { Int(rng.uniform(UInt64(max(1, n)))) }
        let norm = p.items.map { MetadataNormalizer.normalize($0.raw) }
        var post: [String: [Int]] = [:]
        for (i, n) in norm.enumerated() { for w in Set(n.split(separator: " ")) { post[String(w), default: []].append(i) } }
        let vocabKeys = post.keys.sorted()
        var vocab: [String: Int] = [:]
        for (w, l) in post where w.count >= 3 { vocab[w] = l.count }
        let spelling = SpellingIndex(words: vocab)
        func ftsSearch(_ q: String) -> [Int] {
            let qt = MetadataNormalizer.normalize(q).split(separator: " ").map(String.init); guard !qt.isEmpty else { return [] }
            var acc: Set<Int>?
            for t in qt {
                var s = Set<Int>()
                var lo = 0, hi = vocabKeys.count
                while lo < hi { let m = (lo + hi) / 2; if vocabKeys[m] < t { lo = m + 1 } else { hi = m } }
                var j = lo
                while j < vocabKeys.count, vocabKeys[j].hasPrefix(t) { s.formUnion(post[vocabKeys[j]]!); j += 1; if s.count > 50000 { break } }
                acc = acc == nil ? s : acc!.intersection(s)
            }
            let rows = Array(acc ?? []).sorted()
            let scored = rows.prefix(2000).enumerated().map { (i, r) in (r, GlobalSearchService.score(title: p.items[r].raw, query: q, position: i)) }
            return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(24).map(\.0)
        }
        func run(_ q: String) -> [Int] { let r = ftsSearch(q); if !r.isEmpty { return r }; if let c = spelling.correct(q) { return ftsSearch(c) }; return [] }
        let goldRows = p.items.enumerated().filter { $0.element.gold != nil }
        guard !goldRows.isEmpty else { return }
        var kinds: [String: (n: Int, r1: Int, r5: Int)] = [:]
        var times: [Double] = []
        let sample = min(160, goldRows.count)
        for _ in 0..<sample {
            let target = goldRows[u(goldRows.count)].element
            let title = ArtworkNameCleaner.clean(target.raw, year: target.year)
            let words = title.split(separator: " ").map(String.init)
            guard !title.isEmpty else { continue }
            var qs: [(String, String)] = [("exact", title)]
            if let w = words.max(by: { $0.count < $1.count }), w.count >= 5, let r = title.range(of: w) {
                var c = Array(w); let i = 1 + u(c.count - 2)
                switch u(3) { case 0: c.remove(at: i); case 1: c.swapAt(i, i + 1 < c.count ? i + 1 : i - 1); default: c[i] = Character(UnicodeScalar(97 + UInt8(u(26)))) }
                qs.append(("typo", title.replacingCharacters(in: r, with: String(c))))
            }
            if title.count >= 7 { qs.append(("prefix", String(title.prefix(max(4, title.count * 2 / 3))))) }
            if target.noise.contains("translit") || ["hi", "te", "ta", "ml", "kn", "ko", "ja", "ar", "tr"].contains(target.lang ?? "") {
                var v = title.lowercased()
                for (a, b) in [("aa", "a"), ("ee", "i"), ("oo", "u"), ("th", "t"), ("w", "v"), ("ay", "ai")] where v.contains(a) { v = v.replacingOccurrences(of: a, with: b); break }
                if v != title.lowercased() { qs.append(("translit", v)) }
            }
            for (kind, q) in qs {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let res = run(q)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                var k = kinds[kind] ?? (0, 0, 0); k.n += 1
                if res.first.map({ p.items[$0].gold == target.gold }) == true { k.r1 += 1 }
                if res.prefix(5).contains(where: { p.items[$0].gold == target.gold }) { k.r5 += 1 }
                kinds[kind] = k
            }
        }
        for (k, v) in kinds { put(p.persona, "search", k + ".n", Double(v.n)); put(p.persona, "search", k + ".r1", Double(v.r1) / Double(max(1, v.n))); put(p.persona, "search", k + ".r5", Double(v.r5) / Double(max(1, v.n))) }
        times.sort(); put(p.persona, "search", "p50ms", times[times.count / 2]); put(p.persona, "search", "p95ms", times[Int(Double(times.count) * 0.95)])
        // Short queries ("av", "the") and the typo corrector's own latency at this vocabulary size.
        var short: [Double] = []
        for q in ["avn", "the", "lo", "mar", "ban", "dr"] { let t0 = DispatchTime.now().uptimeNanoseconds; _ = run(q); short.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
        put(p.persona, "search", "shortMaxMs", short.max()!)
        let t0 = DispatchTime.now().uptimeNanoseconds; for q in ["zzqxvb", "avngers", "intersteller"] { _ = spelling.correct(q) }
        put(p.persona, "search", "correctMs", Double(DispatchTime.now().uptimeNanoseconds - t0) / 3e6)
        put(p.persona, "search", "vocab", Double(vocab.count)); put(p.persona, "search", "rows", Double(p.items.count))
    }

    // MARK: Smart Mix
    static func candidates(_ p: PersonaCorpus.Persona) -> [SMCandidate] {
        p.items.map { it in
            var c = SMCandidate(id: it.id)
            c.kind = it.kind == "series" ? .series : .movie
            c.key = IdentityKey.make(it.raw); c.year = it.year; c.added = it.addedDays; c.rating = it.rating.isEmpty ? nil : it.rating; c.q = it.quality
            c.lang = it.lang.flatMap { PersonaCorpus.langName[$0] }; c.folder = it.category; c.genre = it.genre.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            c.genres = SMGenres.tokens(it.genre); c.poster = it.poster; c.backdrop = it.poster
            c.restricted = it.restricted || (p.kids && it.genre.lowercased().contains("horror"))
            return c
        }
    }
    static func mix(_ p: PersonaCorpus.Persona, _ put: (String, String, String, Double) -> Void) {
        guard !p.items.isEmpty else { return }
        let cands = candidates(p)
        let langs = Dictionary(grouping: cands.compactMap(\.lang), by: { $0 }).mapValues(\.count).sorted { $0.value > $1.value }
        let pref = langs.first?.key
        func ctx(_ n: Int) -> SMContext { var c = SMContext(profile: "eval", dayKey: "2026-11-22", refreshCounter: n, preferredLang: pref, poolCap: cands.count > 50000 ? 800 : nil); c.kids = p.kids; return c }
        let shelves = [SMShelf.hero, SMShelf.topWeek, SMShelf.trendingLibrary, SMShelf.langPref]
        func home(_ n: Int) -> [SMShelfResult] {
            let c = ctx(n); let prep = SmartMixEngine.prepare(cands, preferredLang: pref)
            var ids = shelves
            ids += SMGenres.select(counts: SmartMixEngine.genreCounts(prep), ctx: c).map { SMGenres.shelfId($0) }
            return ids.map { SmartMixEngine.build(shelfId: $0, prepared: prep, ctx: c) }
        }
        let runs = (0..<5).map(home)
        let first = runs[0]
        let keyOf = Dictionary(uniqueKeysWithValues: cands.map { ($0.id, $0) })
        var seenKeys = Set<String>(), crossDup = 0, picks = 0, empty = 0, fill = 0.0, restricted = 0, adultInKids = 0, langHit = 0
        var genres = Set<String>()
        for r in first {
            picks += r.picks.count
            if r.picks.isEmpty { empty += 1 }
            let cap = SMShelf.isGenre(r.shelfId) ? 14 : (SmartMixScoring.shelf(r.shelfId, mode: .weekly).size)
            fill += min(1, Double(r.picks.count) / Double(max(1, cap)))
            for pk in r.picks {
                if !seenKeys.insert(pk.kind.rawValue + pk.key).inserted { crossDup += 1 }
                if keyOf[pk.id]?.restricted == true { restricted += 1 }
                if let pf = pref, pk.lang == pf { langHit += 1 }
                if let g = pk.genre { genres.insert(g) }
                _ = adultInKids
            }
        }
        // Within-shelf duplicate copies of one TMDB title (the library's twin copies that the identity key failed to merge).
        let goldOf = Dictionary(uniqueKeysWithValues: p.items.map { ($0.id, $0.gold) })
        var twinsInShelf = 0
        for r in first { var s = Set<Int>(); for pk in r.picks { if let g = goldOf[pk.id] ?? nil, !s.insert(g).inserted { twinsInShelf += 1 } } }
        // Reload repetition: share of a shelf's picks that were also in the previous load.
        var rep = 0.0, repN = 0.0
        for n in 1..<5 { for (a, b) in zip(runs[n - 1], runs[n]) where !a.picks.isEmpty { rep += Double(Set(a.ids).intersection(b.ids).count) / Double(a.picks.count); repN += 1 } }
        let det = zip(home(0), first).allSatisfy { $0.ids == $1.ids }
        put(p.persona, "mix", "shelves", Double(first.count)); put(p.persona, "mix", "emptyShelfRate", Double(empty) / Double(max(1, first.count)))
        put(p.persona, "mix", "shelfFill", fill / Double(max(1, first.count))); put(p.persona, "mix", "crossRowDupRate", Double(crossDup) / Double(max(1, picks)))
        put(p.persona, "mix", "twinsInShelf", Double(twinsInShelf)); put(p.persona, "mix", "reloadRepeat", rep / max(1, repN)); put(p.persona, "mix", "deterministic", det ? 1 : 0)
        put(p.persona, "mix", "restrictedLeaks", Double(restricted)); put(p.persona, "mix", "distinctGenres", Double(genres.count)); put(p.persona, "mix", "prefLangShare", Double(langHit) / Double(max(1, picks)))
        put(p.persona, "mix", "picks", Double(picks))
    }

    // MARK: guide mapping
    static func guide(_ p: PersonaCorpus.Persona, _ g: [PersonaCorpus.GuideItem], _ put: (String, String, String, Double) -> Void) {
        guard !p.channels.isEmpty else { return }
        let gs = g.map { GuideMapGuideChannel(sourceID: "provider:p1", xmltvID: $0.id, names: [$0.name], country: $0.country, language: $0.language, priority: 10) }
        let chans = p.channels.enumerated().map { GuideMapChannel(id: String($0.offset), name: $0.element.name, tvgID: $0.element.tvg, providerID: nil, country: $0.element.country, language: nil, ownGuideSource: nil) }
        let res = GuideMappingEngine.map(channels: chans, guide: gs)
        var t = Tally(); var tags: [String: Tally] = [:]
        for (i, r) in res.enumerated() {
            let c = p.channels[i]; var o: Int
            if let gold = c.gold { o = r.match.map { $0.xmltvID == gold ? 0 : 1 } ?? 2 } else { o = r.match == nil ? 0 : 3 }
            apply(&t, o)
            if o != 0, let d = dumpDir { dump(d, "guide", "\(p.persona)\t\(o)\t\(c.noise.joined(separator: ","))\t\(c.name)\t\(c.tvg ?? "")\t\(c.gold ?? "")\t\(r.match?.xmltvID ?? "")") }
            for n in c.noise { var x = tags[n] ?? Tally(); apply(&x, o); tags[n] = x }
        }
        put(p.persona, "guide", "n", Double(res.count)); put(p.persona, "guide", "precision", Double(t.correct) / max(1, Double(t.correct + t.wrong + t.spurious)))
        put(p.persona, "guide", "recall", Double(t.correct) / max(1, Double(t.correct + t.wrong + t.miss))); put(p.persona, "guide", "wrongRate", Double(t.wrong + t.spurious) / Double(max(1, res.count)))
        for (k, x) in tags { let n = Double(x.correct + x.wrong + x.miss + x.spurious); put(p.persona, "guide.noise", k + ".recall", Double(x.correct) / max(1, n)); put(p.persona, "guide.noise", k + ".wrong", Double(x.wrong + x.spurious) / max(1, n)) }
    }
}
