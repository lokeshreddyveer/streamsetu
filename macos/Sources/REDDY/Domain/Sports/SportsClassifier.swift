import Foundation

/// Decides, from a guide programme and its channel alone, whether it is a real sports event, and what shape: two sides, a race session, a round of a tournament, a fight card, or (only when the
/// competition and a specific final or match number are named) a generic event. Deterministic: the same input always gives the same answer; nothing is learned or fetched. Studio shows, news,
/// highlights, documentaries, replays and "sports channel" listings are not events, and a listing that only says "Cricket Live" is skipped rather than guessed at.
enum SportsClassifier {
    struct Hint: Equatable, Sendable { var value: String; var source: MetadataSource }

    struct Match: Equatable, Sendable {
        var sport: Sport
        var kind: SportsEventKind
        var competition: String?
        /// In the order the title gives them (home side first for "A @ B"). Empty for an event with no sides.
        var participants: [String]
        /// "race", "qualifying", "practice 2", "round 3", "final", "main card"…
        var stage: String?
        var title: String
        var language: Hint?
        var quality: Hint?
        var variant: String?
        var confidence: Double
        /// What two feeds of the same event share. For two sides it does not depend on their order, so "A vs B" and "B @ A" are one event; for other events it is the event's own name and stage.
        var identity: String
        /// A comparable form of the competition, or nil when the listing names none.
        var competitionKey: String?
    }

    // MARK: vocabulary

    /// Words and phrases (lower case, accents removed) that name a sport or a competition of it. A phrase is up to three words.
    private static let vocabulary: [Sport: (competitions: [String], words: [String])] = [
        .football: (["premier league", "la liga", "laliga", "serie a", "bundesliga", "ligue 1", "eredivisie", "champions league", "europa league", "conference league", "mls", "fa cup", "carabao cup", "copa del rey",
                     "copa america", "copa libertadores", "nations league", "concacaf", "afcon", "liga mx", "scottish premiership", "isl", "a league", "uefa", "fifa", "efl cup", "dfb pokal", "coppa italia",
                     "super lig", "saudi pro league", "club world cup"], ["soccer", "football"]),
        .cricket: (["ipl", "t20", "t20i", "odi", "test match", "the ashes", "ashes", "bbl", "big bash", "psl", "cpl", "the hundred", "county championship", "ranji trophy", "wpl", "sa20", "ilt20", "icc",
                    "asia cup", "bpl", "lpl", "champions trophy"], ["cricket"]),
        .basketball: (["nba", "wnba", "euroleague", "ncaab", "fiba", "g league", "nbl", "liga acb"], ["basketball"]),
        .americanFootball: (["nfl", "ncaaf", "college football", "super bowl", "cfl", "xfl", "ufl"], ["american football"]),
        .baseball: (["mlb", "npb", "kbo", "world series", "ncaa baseball"], ["baseball"]),
        .iceHockey: (["nhl", "khl", "stanley cup", "ahl", "shl", "iihf"], ["ice hockey"]),
        .tennis: (["atp", "wta", "wimbledon", "roland garros", "french open", "australian open", "us open", "grand slam", "davis cup", "billie jean king cup", "laver cup", "itf", "atp finals", "wta finals"], ["tennis"]),
        .motorsport: (["formula 1", "formula one", "f1", "formula 2", "formula 3", "f2", "f3", "formula e", "motogp", "moto2", "moto3", "nascar", "indycar", "wrc", "world endurance", "wec", "le mans", "dtm",
                       "superbike", "wsbk", "supercars", "grand prix", "rally"], ["motorsport", "motorsports"]),
        .golf: (["pga", "lpga", "pga tour", "liv golf", "ryder cup", "solheim cup", "presidents cup", "the open", "open championship", "dp world tour", "the masters", "augusta", "us open golf", "masters tournament"], ["golf"]),
        .boxing: (["wbc", "wba", "ibf", "wbo", "title fight"], ["boxing"]),
        .mma: (["ufc", "bellator", "pfl", "one championship", "cage warriors", "ksw", "ufc fight night"], ["mma", "mixed martial arts"]),
        .rugby: (["six nations", "rugby championship", "super rugby", "premiership rugby", "urc", "top 14", "nrl", "heineken champions cup", "rugby world cup", "gallagher premiership", "pro d2", "rugby league"], ["rugby"]),
    ]
    private static let allVocabulary: Set<String> = Set(vocabulary.values.flatMap { $0.competitions + $0.words })
    private static func hasSeparator(_ lower: String) -> Bool { [" vs", " v ", " v.", " @ ", " versus ", " - ", " – ", " — "].contains { lower.contains($0) } }

    /// A competition word that does not say which series it is (every motorsport has Grand Prix); it counts as evidence of the sport but is not used as the competition.
    private static let weakCompetitions: Set<String> = ["grand prix", "rally", "the open", "icc"]
    /// One-off events that are complete on their own.
    private static let singleEvents: Set<String> = ["super bowl", "the ashes"]

    /// Words that make a listing a programme about sport rather than the sport itself.
    private static let notAnEvent: Set<String> = ["news", "magazine", "highlights", "highlight", "review", "preview", "analysis", "documentary", "docuseries", "studio", "talk", "podcast", "show", "daily", "weekly",
                                                   "best of", "classic", "classics", "greatest", "story", "stories", "history", "inside", "behind the scenes", "countdown", "pre match", "post match", "prematch", "postmatch",
                                                   "pregame", "postgame", "replay", "repeat", "rerun", "re run", "encore", "on demand", "archive", "archived", "condensed", "goals", "bulletin", "report", "reports", "debate",
                                                   "extra time", "lounge", "tonight", "roundup", "round up", "recap", "reaction", "verdict", "special report", "full match replay", "movie", "film", "game show", "weigh in", "press conference"]
    private static let notAnEventCategory = ["news", "documentary", "movie", "film", "series", "talk", "magazine", "reality", "drama", "comedy", "cartoon", "kids", "children", "entertainment"]

    private static let languages: [String: String] = [
        "english": "en", "spanish": "es", "espanol": "es", "french": "fr", "francais": "fr", "german": "de", "deutsch": "de", "arabic": "ar", "hindi": "hi", "telugu": "te", "tamil": "ta", "kannada": "kn",
        "malayalam": "ml", "bengali": "bn", "marathi": "mr", "urdu": "ur", "punjabi": "pa", "portuguese": "pt", "italian": "it", "turkish": "tr", "russian": "ru", "polish": "pl", "dutch": "nl",
        "persian": "fa", "farsi": "fa", "mandarin": "zh", "chinese": "zh", "japanese": "ja", "korean": "ko", "thai": "th", "indonesian": "id", "en": "en", "es": "es", "fr": "fr", "de": "de", "ar": "ar",
        "hi": "hi", "te": "te", "ta": "ta", "pt": "pt", "it": "it", "tr": "tr", "ru": "ru", "pl": "pl", "nl": "nl",
    ]
    private static let qualities: [String: String] = ["4k": "4K", "uhd": "4K", "2160p": "4K", "fhd": "FHD", "1080p": "FHD", "1080i": "FHD", "hd": "HD", "720p": "HD", "hevc": "HD", "sd": "SD", "576p": "SD", "480p": "SD"]
    private static let variants: [String: String] = ["home": "home", "away": "away", "alt": "alt", "alternate": "alt", "clean": "clean"]
    private static let plainTags: Set<String> = ["live", "new", "feed", "commentary", "multi", "audio", "main", "world", "international", "stream", "channel", "hdr", "dolby", "the", "from"]

    // MARK: entry point

    /// nil when the programme is not a clear sports event. `fastReject: false` skips the early refusal and takes the full path (the reference the shortcut is tested against). `channelLanguage` and `channelQuality` are what the playlist itself says (the provider); anything read out of a name is marked as a hint.
    static func classify(title: String, subtitle: String? = nil, description: String? = nil, category: String? = nil, channelName: String = "", channelCategory: String? = nil,
                         channelLanguage: String? = nil, channelQuality: String? = nil, fastReject: Bool = true) -> Match? {
        guard !title.isEmpty, title.count <= 200 else { return nil }
        // Cheap early refusal for the great majority of listings: an event has two sides (a separator) or names a sport or competition in its own title. Nothing else can pass below.
        let lower = title.lowercased()
        if fastReject, !hasSeparator(lower), !phrases(tokens(of: fold(lower)), upTo: 3).contains(where: { allVocabulary.contains($0) }) { return nil }
        let cat = fold(category ?? "")
        if notAnEventCategory.contains(where: { cat.contains($0) }) { return nil }

        var tags = Tags()
        var text = cleaned(title, into: &tags)
        if separatorRange(in: text) == nil, let sub = subtitle, !sub.isEmpty {           // the competition in the title, the fixture in the sub-title
            var subTags = Tags(); let s = cleaned(sub, into: &subTags)
            if separatorRange(in: s) != nil { text = text + ": " + s; tags.merge(subTags) }
        }
        let words = tokens(of: fold(text))
        guard !words.isEmpty, !containsAny(notAnEvent, in: words) else { return nil }

        var nameTags = Tags(); _ = cleaned(channelName, into: &nameTags)                  // a hint from the channel name ("… HD", "… Hindi") when nothing better is known
        let language = pick(provider: channelLanguage.flatMap(languageCode), title: tags.language, name: nameTags.language)
        let quality = pick(provider: channelQuality.flatMap(qualityCode), title: tags.quality, name: nameTags.quality)

        guard let found = detectSport(titleWords: words, evidenceWords: tokens(of: [fold(text), cat, fold(channelCategory ?? "")].joined(separator: " ")), channelWords: tokens(of: fold(channelName))) else { return nil }

        func build(kind: SportsEventKind, competition: String?, participants: [String], stage: String?, title: String, identity: String, confidence: Double) -> Match {
            Match(sport: found.sport, kind: kind, competition: competition, participants: participants, stage: stage, title: title, language: language, quality: quality, variant: tags.variant,
                  confidence: confidence, identity: identity, competitionKey: competition.map { teamKey($0) }.flatMap { $0.isEmpty ? nil : $0 })
        }

        // 1. two sides
        if let sides = splitSides(text) {
            var c = found.fromCompetition ? 0.95 : (found.fromTitle ? 0.85 : 0.7)
            if !sides.strong { c -= 0.1 }
            let competition = sides.competition ?? found.competition
            // order does not matter for who is playing: A vs B and B @ A are the same event
            let identity = "\(found.sport.rawValue)|h2h|" + sides.participants.map { teamKey($0) }.sorted().joined(separator: "|")
            return build(kind: .headToHead, competition: competition, participants: sides.participants, stage: nil, title: sides.participants.joined(separator: " vs "), identity: identity, confidence: c)
        }

        // 2. an event without two sides: by the sport
        guard found.fromTitle || found.fromCompetition else { return nil }                // the title itself must say the sport
        let stage = stageOf(found.sport, words)
        let name = eventName(words, competition: found.keyword, stage: stage)
        switch found.sport {
        case .motorsport:
            guard !name.isEmpty, stage != nil || found.keyword == "grand prix" || words.contains("grand") && words.contains("prix") else { return nil }
            let st = stage ?? "race"
            return build(kind: .raceSession, competition: found.competition, participants: [], stage: st, title: collapse(text), identity: "motorsport|race|\(name)|\(st)", confidence: stage == nil ? 0.65 : 0.85)
        case .golf, .tennis:
            guard let st = stage, !name.isEmpty || found.fromCompetition else { return nil }
            let n = name.isEmpty ? (found.keyword ?? "") : name
            return build(kind: .tournamentRound, competition: found.competition, participants: [], stage: st, title: collapse(text), identity: "\(found.sport.rawValue)|round|\(n)|\(st)", confidence: found.fromCompetition ? 0.85 : 0.7)
        case .boxing, .mma:
            let numbered = words.contains { $0.allSatisfy(\.isNumber) && $0.count >= 2 }
            guard (found.fromCompetition || numbered), !name.isEmpty || numbered, stage != nil || numbered else { return nil }
            return build(kind: .fightCard, competition: found.competition, participants: [], stage: stage, title: collapse(text), identity: "\(found.sport.rawValue)|card|\(name)|\(stage ?? "")", confidence: found.fromCompetition ? 0.85 : 0.7)
        default:
            // a team sport with no sides: only a known competition with a specific final, qualifier or match number, or a one-off such as the Super Bowl
            guard found.fromCompetition, let keyword = found.keyword else { return nil }
            let st = genericStage(words)
            guard st != nil || singleEvents.contains(keyword) else { return nil }
            return build(kind: .generic, competition: found.competition, participants: [], stage: st, title: collapse(text), identity: "\(found.sport.rawValue)|generic|\(name)|\(st ?? "")", confidence: 0.7)
        }
    }

    private static func pick(provider: String?, title: String?, name: String?) -> Hint? {
        if let p = provider { return Hint(value: p, source: .provider) }
        if let v = title ?? name { return Hint(value: v, source: .parsedFromName) }
        return nil
    }

    // MARK: tags

    private struct Tags {
        var language: String?, quality: String?, variant: String?
        mutating func merge(_ o: Tags) { language = language ?? o.language; quality = quality ?? o.quality; variant = variant ?? o.variant }
    }

    /// Removes "(HD)", "[English]", "| FHD", "- Home Feed", "LIVE:" and trailing quality or language words, remembering what they said.
    private static func cleaned(_ raw: String, into tags: inout Tags) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["🔴", "●", "live:", "live -", "live |", "live from", "live –", "live —", "live"] where s.lowercased().hasPrefix(lead) && (lead != "live" || s.dropFirst(4).first == " ") {
            s = String(s.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-|–—"))); break
        }
        while let open = s.firstIndex(where: { $0 == "(" || $0 == "[" }), let close = s[open...].firstIndex(where: { $0 == ")" || $0 == "]" }) {
            let inner = String(s[s.index(after: open)..<close])
            if isOnlyTags(inner) { absorb(inner, into: &tags); s.removeSubrange(open...close) } else { break }
        }
        for sep in [" | ", " – ", " — ", " - "] {
            while let r = s.range(of: sep, options: .backwards), isOnlyTags(String(s[r.upperBound...])) { absorb(String(s[r.upperBound...]), into: &tags); s = String(s[..<r.lowerBound]) }
        }
        var parts = s.split(separator: " ").map(String.init)
        while let last = parts.last, isTag(last) { absorb(last, into: &tags); parts.removeLast() }
        return collapse(parts.joined(separator: " "))
    }
    private static func isTag(_ word: String) -> Bool { let w = fold(word); return languages[w] != nil || qualities[w] != nil || variants[w] != nil || plainTags.contains(w) }
    private static func isOnlyTags(_ s: String) -> Bool { let ws = tokens(of: fold(s)); return !ws.isEmpty && ws.allSatisfy { languages[$0] != nil || qualities[$0] != nil || variants[$0] != nil || plainTags.contains($0) } }
    private static func absorb(_ s: String, into tags: inout Tags) {
        for w in tokens(of: fold(s)) {
            if let l = languages[w], tags.language == nil { tags.language = l }
            if let q = qualities[w], tags.quality == nil { tags.quality = q }
            if let v = variants[w], tags.variant == nil { tags.variant = v }
        }
    }
    static func languageCode(_ s: String) -> String? { languages[fold(s)] ?? (fold(s).count == 2 ? fold(s) : nil) }
    static func qualityCode(_ s: String) -> String? { tokens(of: fold(s)).compactMap { qualities[$0] }.first }

    // MARK: sport

    private struct Found { var sport: Sport; var competition: String?; var keyword: String?; var fromCompetition: Bool; var fromTitle: Bool }

    /// The sport named by a competition or sport word: the longest phrase wins, a competition beating a plain sport word. The title and the guide's category count most; the channel's name only
    /// counts when nothing else says, and never as a competition.
    private static func detectSport(titleWords: [String], evidenceWords: [String], channelWords: [String]) -> Found? {
        func hit(_ words: [String]) -> Found? {
            let set = phrases(words, upTo: 3)
            var best: (score: Int, sport: Sport, keyword: String, competition: Bool)?
            for sport in Sport.allCases {
                guard let v = vocabulary[sport] else { continue }
                for k in v.competitions where set.contains(k) { let s = (weakCompetitions.contains(k) ? 500 : 1000) + k.count; if best == nil || s > best!.score { best = (s, sport, k, true) } }
                for k in v.words where set.contains(k) { let s = k.count; if best == nil || s > best!.score { best = (s, sport, k, false) } }
            }
            guard let b = best else { return nil }
            let weak = weakCompetitions.contains(b.keyword)
            return Found(sport: b.sport, competition: b.competition && !weak ? display(b.keyword) : nil, keyword: b.keyword, fromCompetition: b.competition, fromTitle: true)
        }
        if let f = hit(titleWords) { return f }
        if var f = hit(evidenceWords) { f.fromTitle = false; return f }
        if var f = hit(channelWords) { f.fromTitle = false; f.fromCompetition = false; f.competition = nil; return f }
        return nil
    }

    private static func display(_ keyword: String) -> String {
        let upper: Set<String> = ["nba", "nfl", "nhl", "mlb", "ipl", "ufc", "pga", "atp", "wta", "mls", "uefa", "fifa", "icc", "wbc", "wba", "ibf", "wbo", "pfl", "wrc", "dtm", "t20", "odi", "f1", "f2", "f3", "bbl", "psl", "cpl", "wpl",
                                  "khl", "ahl", "shl", "nrl", "urc", "isl", "ksw", "npb", "kbo", "cfl", "xfl", "ufl", "wnba", "ncaab", "ncaaf", "lpga", "motogp"]
        return upper.contains(keyword) ? keyword.uppercased() : keyword.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: stages and names

    /// The part of an individual-sport event: a session, a round or a segment of a card.
    private static func stageOf(_ sport: Sport, _ w: [String]) -> String? {
        let set = phrases(w, upTo: 3)
        func number(after word: String) -> String? { w.firstIndex(of: word).flatMap { i in i + 1 < w.count && w[i + 1].allSatisfy(\.isNumber) ? w[i + 1] : nil } }
        switch sport {
        case .motorsport:
            if set.contains("sprint qualifying") || set.contains("sprint shootout") { return "sprint qualifying" }
            if w.contains("sprint") { return "sprint" }
            if w.contains("qualifying") { return "qualifying" }
            for fp in ["fp1": "1", "fp2": "2", "fp3": "3"] where w.contains(fp.key) { return "practice \(fp.value)" }
            if w.contains("practice") { return number(after: "practice").map { "practice \($0)" } ?? "practice" }
            if w.contains("race") { return "race" }
            return nil
        case .golf, .tennis:
            if set.contains("final round") { return "final round" }
            if let n = number(after: "round") { return "round \(n)" }
            if let n = number(after: "day") { return "day \(n)" }
            if set.contains("semi final") || w.contains("semifinal") || w.contains("semifinals") { return "semi-final" }
            if set.contains("quarter final") || w.contains("quarterfinal") || w.contains("quarterfinals") { return "quarter-final" }
            if w.contains("final") || w.contains("finals") { return "final" }
            if w.contains("qualifying") { return "qualifying" }
            return nil
        case .boxing, .mma:
            if set.contains("early prelims") { return "early prelims" }
            if w.contains("prelims") { return "prelims" }
            if set.contains("main card") { return "main card" }
            if set.contains("main event") { return "main event" }
            if set.contains("fight night") { return "fight night" }
            return nil
        default: return nil
        }
    }

    private static func genericStage(_ w: [String]) -> String? {
        let set = phrases(w, upTo: 2)
        for s in ["semi final", "quarter final", "final", "qualifier", "playoff", "opening ceremony"] where set.contains(s) { return s }
        for noun in ["match", "game", "test"] { if let i = w.firstIndex(of: noun), i + 1 < w.count, w[i + 1].allSatisfy(\.isNumber) { return "\(noun) \(w[i + 1])" } }
        return nil
    }

    /// What names the event once the competition, the stage and the filler are taken away ("monaco grand prix", "ufc 300", "mens singles").
    private static func eventName(_ words: [String], competition: String?, stage: String?) -> String {
        var drop = Set<String>(["live", "the", "of", "at", "in", "round", "day", "final", "finals", "semi", "quarter", "race", "qualifying", "practice", "sprint", "shootout", "fp1", "fp2", "fp3", "main", "card", "event",
                                "prelims", "early", "fight", "night", "round", "tournament", "championship", "highlights"])
        for sport in Sport.allCases { for w in vocabulary[sport]?.words ?? [] { w.split(separator: " ").forEach { drop.insert(String($0)) } } }
        if let c = competition, !weakCompetitions.contains(c) { c.split(separator: " ").forEach { drop.insert(String($0)) } }
        var out: [String] = []
        for (i, w) in words.enumerated() {
            if drop.contains(w) { continue }
            if w.allSatisfy(\.isNumber), i > 0, ["practice", "round", "day"].contains(words[i - 1]) { continue }          // the number of a stage is not part of the event's name
            out.append(w)
        }
        return out.joined(separator: " ")
    }

    private static func phrases(_ words: [String], upTo n: Int) -> Set<String> {
        var set = Set<String>()
        for len in 1...n where words.count >= len { for i in 0...(words.count - len) { set.insert(words[i..<(i + len)].joined(separator: " ")) } }
        return set
    }
    private static func containsAny(_ list: Set<String>, in words: [String]) -> Bool { !list.isDisjoint(with: phrases(words, upTo: 3)) }

    // MARK: sides

    /// Words that belong to a stage of an event, so a dash before them does not separate two sides.
    private static let stageWords: Set<String> = ["round", "final", "finals", "semifinal", "quarterfinal", "semi", "quarter", "race", "qualifying", "practice", "sprint", "stage", "day", "card", "prelims", "main",
                                                  "event", "qualifier", "heat", "fp1", "fp2", "fp3", "matchday", "leg", "group", "week", "session"]
    private static let strongSeparators = [" vs. ", " vs ", " v. ", " v ", " @ ", " versus "]

    private static func separatorRange(in s: String) -> (range: Range<String.Index>, at: Bool)? {
        var best: (Range<String.Index>, Bool)?
        for sep in strongSeparators { if let r = s.range(of: sep, options: .caseInsensitive), best == nil || r.lowerBound < best!.0.lowerBound { best = (r, sep == " @ ") } }
        return best.map { ($0.0, $0.1) }
    }

    /// "A vs B" and its forms, with an optional competition before it. nil when there are not two plausible sides.
    private static func splitSides(_ text: String) -> (participants: [String], competition: String?, strong: Bool)? {
        var competition: String?, strong = true, left: String, right: String, isAt = false
        if let (r, at) = separatorRange(in: text) {
            var l = String(text[..<r.lowerBound])
            if let cut = lastPrefixSeparator(in: l) { competition = collapse(String(l[..<cut.lowerBound])); l = String(l[cut.upperBound...]) }
            left = l; right = trimTail(String(text[r.upperBound...])); isAt = at
        } else {
            let parts = text.components(separatedBy: " - ").flatMap { $0.components(separatedBy: " – ") }.map { collapse($0) }.filter { !$0.isEmpty }
            if parts.count == 2 { left = parts[0]; right = trimTail(parts[1]) }
            else if parts.count == 3 { competition = parts[0]; left = parts[1]; right = trimTail(parts[2]) }
            else { return nil }
            strong = false
            // "Monaco Grand Prix - Race" and "Genesis Invitational - Round 3" are an event and its stage, not two sides
            if tokens(of: fold(parts.joined(separator: " "))).contains(where: { stageWords.contains($0) }) { return nil }
        }
        let a = collapse(left), b = collapse(right)
        guard plausibleSide(a), plausibleSide(b), fold(a) != fold(b) else { return nil }
        return (isAt ? [b, a] : [a, b], competition.flatMap { $0.isEmpty ? nil : $0 }, strong)         // "away @ home" lists the home side first
    }

    private static func lastPrefixSeparator(in s: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for sep in [": ", " | ", " – ", " — ", " - "] { if let r = s.range(of: sep, options: .backwards), best == nil || r.lowerBound > best!.lowerBound { best = r } }
        return best
    }
    private static func trimTail(_ s: String) -> String {
        var out = s
        for sep in [" | ", " – ", " — ", " - ", ": ", " ("] { if let r = out.range(of: sep) { out = String(out[..<r.lowerBound]) } }
        return collapse(out)
    }
    private static func plausibleSide(_ s: String) -> Bool {
        let t = tokens(of: fold(s))
        guard (1...6).contains(t.count), s.count >= 2, s.count <= 60, !t.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return !containsAny(notAnEvent, in: t)
    }

    // MARK: text

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() }
    private static func collapse(_ s: String) -> String { s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|·")) }
    private static func tokens(of s: String) -> [String] { s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init) }

    /// A side's or competition's name for comparing: no accents, case, punctuation or club markers.
    static func teamKey(_ s: String) -> String {
        let drop: Set<String> = ["fc", "cf", "afc", "sc", "ac", "cd", "club", "the"]
        return tokens(of: fold(s)).filter { !drop.contains($0) }.joined(separator: " ")
    }
}
