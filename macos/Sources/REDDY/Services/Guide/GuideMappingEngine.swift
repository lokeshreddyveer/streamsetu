import Foundation

/// Channel-to-guide mapping. A pure function: the same input gives the same output on every platform (shared fixtures in `epg/fixtures/mapping-cases.json`).
/// Order of trust and base confidence:
///   user lock 1.00 | exact tvg id in the channel's own guide 0.99, in another source 0.95 | normalised id 0.90 | provider id 0.85 | alias 0.80 | equal name 0.70 (+0.10 same country, +0.05 same language) | fuzzy 0.40 to 0.65
/// Applied automatically from 0.60. Below that a match is only a suggestion for the manual screen. A tie that cannot be broken is left unmapped.
struct GuideMapChannel: Sendable, Equatable {
    var id: String
    var name: String
    var tvgID: String?
    var providerID: String?
    var country: String?
    var language: String?
    /// The guide source of the channel's own playlist ("provider:<id>"), when it has one.
    var ownGuideSource: String?
    /// Other names the channel is known by (from the public database).
    var altNames: [String] = []
    /// Locked, hidden, adult or Kids-restricted: never matched, never suggested.
    var restricted = false
    /// A manual choice (never recomputed, never overwritten).
    var userLock: GuideMatch?
}

struct GuideMapGuideChannel: Sendable, Equatable {
    var sourceID: String
    var xmltvID: String
    var names: [String]
    var country: String?
    var language: String?
    /// Lower wins on conflict.
    var priority = 10
}

enum GuideMatchMethod: String, Sendable, Codable, CaseIterable { case user, exact, exactOther, normalisedID, provider, alias, name, fuzzy }

struct GuideMatch: Sendable, Equatable, Hashable {
    var guideSourceID: String
    var xmltvID: String
    var method: GuideMatchMethod
    var confidence: Double
    var reason: String
}

enum GuideUnmappedReason: String, Sendable, Equatable { case restricted, noCandidate, ambiguous, belowThreshold }

struct GuideMappingResult: Sendable, Equatable {
    var channelID: String
    /// Applied automatically (confidence >= autoThreshold, or a user lock).
    var match: GuideMatch?
    /// Offered in the manual screen only (0.40 to 0.60).
    var suggestions: [GuideMatch]
    var unmapped: GuideUnmappedReason?
}

struct GuideMappingOptions: Sendable, Equatable {
    var autoThreshold = 0.60
    var suggestionFloor = 0.40
    var fuzzyMinRatio = 0.88
    /// The best fuzzy candidate must beat the runner-up by this much, or the channel stays unmapped.
    var fuzzyMargin = 0.05
    var maxFuzzyComparisons = 2000
}

enum GuideMappingEngine {
    private struct GuideEntry {
        let g: GuideMapGuideChannel
        let index: Int
        let cc: String?
        let lang: String?
        let keys: [ChannelNormalizer.NameKey]
    }

    static func map(channels: [GuideMapChannel], guide: [GuideMapGuideChannel], options: GuideMappingOptions = GuideMappingOptions()) -> [GuideMappingResult] {
        // Indexes over the guide side: one pass, hash lookups afterwards.
        var entries: [GuideEntry] = []
        entries.reserveCapacity(guide.count)
        var byExact: [String: [Int]] = [:]            // "<source>\u{1}<id>" and "\u{2}<id>" (any source)
        var byIDBase: [String: [Int]] = [:]
        var byName: [String: [Int]] = [:]             // name key (base + variant)
        var postings: [String: [Int32]] = [:]         // token -> flat key ids (fuzzy candidates)
        var flat: [(entry: Int, variant: String, size: Int)] = []
        for (i, g) in guide.enumerated() {
            let idCC = ChannelNormalizer.idParts(g.xmltvID).country
            let keys = (g.names + [g.xmltvID.contains(".") ? "" : g.xmltvID]).map(ChannelNormalizer.name).filter { !$0.isEmpty }
            let e = GuideEntry(g: g, index: i, cc: ChannelNormalizer.countryKey(g.country) ?? ChannelNormalizer.countryKey(idCC), lang: ChannelNormalizer.languageKey(g.language), keys: keys)
            entries.append(e)
            byExact[g.sourceID + "\u{1}" + g.xmltvID, default: []].append(i)
            byExact["\u{2}" + g.xmltvID, default: []].append(i)
            byIDBase[ChannelNormalizer.idParts(g.xmltvID).base, default: []].append(i)
            var seenKeys = Set<String>()
            for k in keys {
                if seenKeys.insert(k.key).inserted { byName[k.key, default: []].append(i) }
                let uniq = Set(k.tokens)
                let id = Int32(flat.count)
                flat.append((i, k.variant, uniq.count))
                for t in uniq { postings[t, default: []].append(id) }
            }
        }
        let commonCutoff = max(50, guide.count / 10)

        func better(_ a: Int, _ b: Int) -> Bool {   // lower priority number wins, then lower index (stable)
            let pa = entries[a].g.priority, pb = entries[b].g.priority
            return pa != pb ? pa < pb : a < b
        }
        func pickByPriority(_ idx: [Int]) -> Int? { idx.min(by: better) }

        func mapOne(_ ch: GuideMapChannel, trustIDs: Bool) -> GuideMappingResult {
            if let lock = ch.userLock { return GuideMappingResult(channelID: ch.id, match: lock, suggestions: [], unmapped: nil) }
            if ch.restricted { return GuideMappingResult(channelID: ch.id, match: nil, suggestions: [], unmapped: .restricted) }
            let chCC = ChannelNormalizer.countryKey(ch.country)
            let chLang = ChannelNormalizer.languageKey(ch.language)
            let nameKey = ChannelNormalizer.name(ch.name)
            let ownCC = chCC ?? nameKey.countryPrefix.flatMap(ChannelNormalizer.countryKey)

            func result(_ i: Int, _ method: GuideMatchMethod, _ conf: Double, _ reason: String) -> GuideMappingResult {
                let m = GuideMatch(guideSourceID: entries[i].g.sourceID, xmltvID: entries[i].g.xmltvID, method: method, confidence: conf, reason: reason)
                return GuideMappingResult(channelID: ch.id, match: conf >= options.autoThreshold ? m : nil, suggestions: conf >= options.autoThreshold ? [] : [m], unmapped: conf >= options.autoThreshold ? nil : .belowThreshold)
            }
            /// Several candidates: narrow by country, then language; still several -> nil (ambiguous).
            func narrow(_ idx: [Int]) -> (Int, Double)? {
                if idx.count == 1 { return (idx[0], 0) }
                var pool = idx
                var bonus = 0.0
                if let c = ownCC {
                    let same = pool.filter { entries[$0].cc == c }
                    if !same.isEmpty && same.count < pool.count { pool = same; bonus += 0.10 }
                    else if !same.isEmpty { bonus += 0.10 }
                }
                if pool.count > 1, let l = chLang {
                    let same = pool.filter { entries[$0].lang == l }
                    if !same.isEmpty && same.count < pool.count { pool = same; bonus += 0.05 }
                }
                if pool.count == 1 { return (pool[0], bonus) }
                // Several sources carry a candidate: the highest priority source wins when it names exactly one channel.
                let best = pool.map { entries[$0].g.priority }.min() ?? 0
                let top = pool.filter { entries[$0].g.priority == best }
                if Set(top.map { entries[$0].g.xmltvID }).count == 1, let p = pickByPriority(top) { return (p, bonus) }
                return nil
            }

            /// An id found only in another source (the own playlist's guide is trusted: shared case 46) that names a channel with nothing in common with this channel's name is a wrong id (providers copy ids around): the name is tried first.
            func guarded(_ i: Int, _ r: GuideMappingResult) -> GuideMappingResult {
                guard trustIDs, r.match != nil, !nameKey.isEmpty else { return r }
                func split(_ t: [String]) -> (words: Set<String>, digits: Set<String>) { (Set(t.filter { $0.contains { !$0.isNumber } }), Set(t.filter { $0.allSatisfy(\.isNumber) })) }
                let a = split(nameKey.tokens)
                // Agreeing means a word in common and the same numbers ("ESPN 2" is not "ESPN", "RAI 1" is not "La 1").
                if entries[i].keys.contains(where: { let b = split($0.tokens); return !a.words.isDisjoint(with: b.words) && a.digits == b.digits }) { return r }
                var again = ch; again.tvgID = nil; again.providerID = nil
                let alt = mapOne(again, trustIDs: false)
                if let am = alt.match, am.method == .name || am.method == .alias { return alt }
                return r
            }
            // 2. exact tvg id
            if trustIDs, let tvg = ch.tvgID?.trimmingCharacters(in: .whitespaces), !tvg.isEmpty {
                if let own = ch.ownGuideSource, let hit = byExact[own + "\u{1}" + tvg], let p = pickByPriority(hit) { return result(p, .exact, 0.99, "id in own guide") }
                if let hit = byExact["\u{2}" + tvg], let p = pickByPriority(hit) { return guarded(p, result(p, .exactOther, 0.95, "id in another guide")) }
                // 3. normalised id
                let b = ChannelNormalizer.idParts(tvg).base
                if let hit = byIDBase[b] {
                    let ok = hit.filter { ChannelNormalizer.idsEqualNormalised(tvg, entries[$0].g.xmltvID) }
                    if let (i, _) = narrow(ok) { return guarded(i, result(i, .normalisedID, 0.90, "id after normalising")) }
                }
            }
            // 4. provider id equals guide id (own guide)
            if trustIDs, let pid = ch.providerID, !pid.isEmpty, let own = ch.ownGuideSource, let hit = byExact[own + "\u{1}" + pid], let p = pickByPriority(hit) { return result(p, .provider, 0.85, "provider id is the guide id") }

            guard !nameKey.isEmpty else { return GuideMappingResult(channelID: ch.id, match: nil, suggestions: [], unmapped: .noCandidate) }

            // 5. alias (public database alternative names)
            if !ch.altNames.isEmpty {
                var hits: [Int] = []
                for alt in ch.altNames {
                    let k = ChannelNormalizer.name(alt)
                    if k.isEmpty || k.variant != nameKey.variant { continue }
                    hits += byName[k.key] ?? []
                }
                let uniq = Array(Set(hits)).sorted()
                if !uniq.isEmpty, let (i, _) = narrow(uniq) { return result(i, .alias, 0.80, "known alternative name") }
            }
            // 6. equal normalised name
            if let hit = byName[nameKey.key] {
                // A guide channel that has a different country than the channel is never an equal-name match across countries.
                let compatible = hit.filter { i in
                    if let a = ownCC, let b = entries[i].cc { return a == b }
                    return true
                }
                if compatible.isEmpty {
                    return GuideMappingResult(channelID: ch.id, match: nil, suggestions: [], unmapped: .noCandidate)
                }
                if let (i, bonus) = narrow(compatible) { return result(i, .name, min(0.89, 0.70 + bonus), "same name") }
                return GuideMappingResult(channelID: ch.id, match: nil, suggestions: [], unmapped: .ambiguous)
            }
            // 6b. the same name without a feed word ("CNN East" -> "CNN"), only when the guide lists exactly that
            if let bare = ChannelNormalizer.withoutFeedWord(nameKey), let hit = byName[bare.key] {
                let compatible = hit.filter { i in if let a = ownCC, let b = entries[i].cc { return a == b }; return true }
                if let (i, bonus) = narrow(compatible), !compatible.isEmpty { return result(i, .name, min(0.89, 0.65 + bonus), "same name without the feed word") }
            }
            // 7. fuzzy: token overlap (Dice over word sets), same country or same language, never across countries
            let a = Set(nameKey.tokens)
            guard !a.isEmpty else { return GuideMappingResult(channelID: ch.id, match: nil, suggestions: [], unmapped: .noCandidate) }
            var shared: [Int32: Int] = [:]
            for t in a { if let list = postings[t], list.count <= commonCutoff { for k in list { shared[k, default: 0] += 1 } } }
            var best: [Int: Double] = [:]          // entry -> best ratio
            var compared = 0
            for k in shared.keys.sorted() {
                compared += 1
                if compared > options.maxFuzzyComparisons { break }
                let f = flat[Int(k)]
                guard f.variant == nameKey.variant else { continue }
                let ratio = 2.0 * Double(shared[k]!) / Double(a.count + f.size)
                guard ratio >= options.fuzzyMinRatio else { continue }
                let e = entries[f.entry]
                if let x = ownCC, let y = e.cc, x != y { continue }
                guard (ownCC != nil && ownCC == e.cc) || (chLang != nil && chLang == e.lang) else { continue }
                best[f.entry] = max(best[f.entry] ?? 0, ratio)
            }
            var scored = best.map { (i: $0.key, ratio: $0.value) }
            scored.sort { $0.ratio != $1.ratio ? $0.ratio > $1.ratio : better($0.i, $1.i) }
            guard let top = scored.first else { return GuideMappingResult(channelID: ch.id, match: nil, suggestions: [], unmapped: .noCandidate) }
            let conf = 0.40 + 0.25 * min(1, (top.ratio - options.fuzzyMinRatio) / (1 - options.fuzzyMinRatio))
            let sugg = scored.prefix(3).map { GuideMatch(guideSourceID: entries[$0.i].g.sourceID, xmltvID: entries[$0.i].g.xmltvID, method: .fuzzy, confidence: 0.40 + 0.25 * min(1, ($0.ratio - options.fuzzyMinRatio) / (1 - options.fuzzyMinRatio)), reason: "similar name") }
            if scored.count > 1, entries[scored[1].i].g.xmltvID != entries[top.i].g.xmltvID, top.ratio - scored[1].ratio < options.fuzzyMargin {
                return GuideMappingResult(channelID: ch.id, match: nil, suggestions: Array(sugg), unmapped: .ambiguous)
            }
            if conf >= options.autoThreshold { return GuideMappingResult(channelID: ch.id, match: sugg[0], suggestions: [], unmapped: nil) }
            return GuideMappingResult(channelID: ch.id, match: nil, suggestions: Array(sugg), unmapped: .belowThreshold)
        }
        return channels.map { mapOne($0, trustIDs: true) }
    }
}
