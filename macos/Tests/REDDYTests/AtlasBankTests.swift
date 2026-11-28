import Testing
import Foundation
@testable import REDDY

struct BankQuestion: Decodable, Sendable { let id: String; let q: String; let expected: [String]; let intent: String; let tags: [String]; let platform: String? }
struct BankFile: Decodable, Sendable { let entries: [BankQuestion] }

/// Replays the question bank against the real imported entries. The seed bank's answer ids were guesses from the app's names; this maps the ones that clearly mean an entry
/// that exists under another id, and reports every id that still does not exist. Nothing is dropped silently: see the report file.
@MainActor @Suite("Atlas: question bank", .serialized) struct AtlasBankTests {
    /// Bank id -> id in the imported data. `exact` are the same thing under another name; `near` are a judgement call (the bank meant a screen, the app has a how-to or a setting for it).
    nonisolated static let exact: [String: String] = [
        "setting.proxyKind": "setting.proxy", "setting.vpnPause": "setting.vpn", "setting.iCloudSync": "setting.icloudSync", "setting.syncLogins": "setting.icloudSync",
        "screen.liveTV": "screen.tab.liveTV", "screen.movies": "screen.tab.movies", "screen.series": "screen.tab.series", "screen.guide": "screen.tab.guide",
        "screen.home.discover": "screen.shortcut.discover", "screen.home.tonight": "screen.shortcut.tonight", "screen.home.favorites": "screen.shortcut.favorites",
        "screen.home.watchLater": "screen.shortcut.watchLater", "screen.home.collections": "screen.shortcut.collections", "screen.home.continueWatching": "screen.shortcut.continueWatching",
        "screen.home.statistics": "screen.shortcut.statistics",
        "screen.settings.parental": "setting.parental", "screen.settings.profiles": "setting.profiles", "screen.settings.keywordAlerts": "setting.keywordAlerts",
        "screen.integrations": "setting.integrations", "screen.downloads": "setting.downloads",
        "recipe.addXtream": "guide.addingXtream", "recipe.addM3U": "guide.addingAnM3uLink", "recipe.addJellyfin": "guide.addingJellyfinOrEmby", "recipe.setupSubtitles": "guide.subtitles",
        "recipe.record": "guide.recordingAndDownloads",
    ]
    nonisolated static let near: [String: String] = [
        "recipe.fixBuffering": "guide.playbackProblems", "diag.playback": "guide.playbackProblems", "recipe.fixEmptyGuide": "guide.guideProblems", "recipe.kidsProfile": "setting.profiles",
        "recipe.moveToNewDevice": "guide.backupAndSync", "screen.settings.backup": "guide.backupAndSync", "screen.settings.artwork": "setting.tmdb", "screen.playlists": "guide.playlists",
        "screen.addPlaylist": "guide.addingAPlaylistOrSource", "screen.shortcuts": "guide.keyboard", "screen.search": "guide.search", "meta.privacySetu": "guide.privacyAndSafety",
        "diag.source": "guide.signInAndLoginProblems", "screen.settings.storage": "setting.maintenance",
    ]

    /// Entries that are the same place, the same setting or the same command described twice, so either one is a right answer. The rule for a row: the person who asked would be fully served by the other entry.
    /// What does NOT belong here: a page that merely contains the setting, a sibling setting, a how-to for a variant (Emby for Jellyfin), a help article that is only related, or a different gesture for the same action.
    /// Entries with the same title (ignoring case and spacing) among screens, pages, controls and settings are accepted by rule in `accepted`; this table has the pairs whose titles differ.
    nonisolated static let alsoRight: [String: Set<String>] = [
        // the Settings block that holds exactly this setting
        "setting.bufferingMode": ["screen.settings.playback.buffering"], "setting.enginePreference": ["screen.settings.playback.playerEngine", "recipe.switchEngine"],
        "setting.preferredAudioLanguage": ["recipe.chooseAudioLanguage"], "setting.subtitlesByDefault": ["recipe.setupSubtitles"], "setting.lanSync": ["recipe.lanSyncPair"],
        "setting.theme": ["screen.settings.appearance.theme"], "setting.proxyKind": ["screen.settings.privacy.proxy", "setting.proxy"], "setting.vpnPause": ["setting.vpn"],
        "setting.appLock": ["screen.settings.privacy.appLock"], "setting.appDNS": ["screen.settings.privacy.appDNS"],
        // a place and the tab, the "Go to" action, the sidebar item or the menu command that opens it
        "screen.guide": ["screen.tab.guide", "screen.destination.guide"], "screen.liveTV": ["screen.tab.liveTV", "screen.destination.liveTV"],
        "screen.movies": ["screen.tab.movies", "screen.destination.movies"], "screen.series": ["screen.tab.series", "screen.destination.series"],
        "screen.home.collections": ["screen.shortcut.collections"], "screen.home.favorites": ["screen.destination.favorites", "screen.shortcut.favorites"],
        "screen.home.watchLater": ["screen.shortcut.watchLater"], "screen.home.continueWatching": ["screen.shortcut.continueWatching", "screen.destination.continueWatching"],
        "screen.home.discover": ["screen.shortcut.discover", "screen.destination.home"],
        "screen.multiview": ["menu.playback.openMultiView"], "screen.search": ["menu.navigate.search", "guide.search"], "screen.shortcuts": ["menu.help.keyboardShortcuts", "guide.keyboard"],
        "screen.feedback": ["menu.help.sendFeedback"], "screen.filesAndServers": ["menu.file.filesAndServers"], "screen.addPlaylist": ["menu.file.addPlaylist", "guide.addingAPlaylistOrSource"],
        "screen.playlists": ["screen.destination.playlists", "guide.playlists"], "screen.settings.channelManager": ["screen.destination.channelManager"],
        "screen.settings.backup": ["screen.settings.library.backup", "recipe.backupRestore"], "screen.settings.storage": ["screen.settings.library.storage"],
        "screen.settings.profiles": ["setting.profiles"], "screen.settings.parental": ["setting.parental"], "screen.integrations": ["setting.integrations"], "screen.downloads": ["setting.downloads"],
        // a command and the how-to for exactly that command; a problem and the diagnosis or help article for exactly that problem
        "menu.file.refreshAll": ["recipe.refreshPlaylist"], "menu.playback.sleepTimer": ["recipe.sleepTimer"],
        "recipe.fixBuffering": ["diag.playback", "guide.playbackProblems"], "recipe.fixEmptyGuide": ["diag.guide", "guide.guideProblems"],
    ]
    /// Same place on the other platform, and the how-to for exactly a setting. Kept apart from the table above so one id can appear in both.
    nonisolated static let alsoRightMore: [String: Set<String>] = [
        // the same place on the other platform: a question asked for "both" devices is answered by either
        "screen.home.favorites": ["screen.ios.favourites"], "screen.home.watchLater": ["screen.ios.watchLater"], "screen.home.collections": ["screen.ios.collections"], "screen.home.statistics": ["screen.ios.statistics"],
        "screen.onYourDevice": ["screen.ios.onYourDevice"], "screen.integrations": ["screen.ios.integrations"], "screen.settings.privacyReport": ["screen.ios.settings.privacyReport"],
        "screen.home.discover": ["screen.ios.tab.home"], "screen.search.tab": ["screen.ios.tab.search"], "screen.feedback": ["screen.ios.settings.feedback"], "screen.settings.profiles": ["screen.ios.settings.profiles"],
        "screen.settings.parental": ["screen.ios.settings.parental"], "screen.settings.channelManager": ["screen.ios.settings.channelManager"], "screen.settings.artwork": ["screen.ios.settings.artwork"],
        "screen.downloads": ["screen.ios.downloads"], "screen.multiview": ["screen.ios.multiView"],
        // the how-to for exactly that setting, and the setting a how-to is about
        "setting.iCloudSync": ["recipe.icloudSync"], "setting.theme": ["recipe.changeTheme"], "setting.accent": ["recipe.changeTheme"], "setting.vpnPause": ["diag.vpnPause"],
        "recipe.fixBuffering": ["setting.bufferingMode"], "screen.liveTV": ["screen.ios.tab.live"], "screen.guide": ["screen.ios.tab.guide"], "screen.movies": ["screen.ios.tab.movies"], "screen.series": ["screen.ios.tab.series"],
        "screen.playlists": ["screen.ios.tab.playlists"], "screen.settings.storage": ["screen.ios.settings.storage"], "recipe.fixWrongArtwork": ["diag.artwork"], "recipe.fixEmptyGuide": ["recipe.shiftGuideTimes"],
    ]
    /// Which equivalences count as a right answer besides the expected id itself. The report prints the MRR for all three so the table's help is visible.
    enum Also: String, CaseIterable { case tableAndTitles = "table + same titles", titlesOnly = "same titles only", none = "expected ids only" }
    nonisolated static func accepted(_ ids: Set<String>, in entries: [AtlasEntry], also: Also = .tableAndTitles) -> Set<String> {
        if also == .none { return ids }
        var out = ids
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let eligible: Set<AtlasKind> = [.screen, .settingsPage, .control, .setting]
        for id in ids {
            if also == .tableAndTitles { if let more = alsoRight[id] { out.formUnion(more) }; if let more = alsoRightMore[id] { out.formUnion(more) } }
            guard let e = entries.first(where: { $0.id == id }), eligible.contains(e.kind) else { continue }
            for o in entries where eligible.contains(o.kind) && norm(o.title) == norm(e.title) && o.platforms.intersection(e.platforms).rawValue != 0 { out.insert(o.id) }
        }
        return out
    }

    struct Outcome { let q: BankQuestion; let rank: Int?; let top: String?; let decision: AtlasDecision; let confidence: Double; let ratio: Double; let intentOK: Bool
        var intent = "", topKind = "", hasValue = false, covers = false, rank3 = false }
    struct Stats { var n = 0, rr = 0.0, r1 = 0, r3 = 0
        mutating func add(_ rank: Int?) { n += 1; if let r = rank { rr += 1 / Double(r); if r == 1 { r1 += 1 }; if r <= 3 { r3 += 1 } } }
        var line: String { n == 0 ? "n=0" : String(format: "n=%3d  MRR@10=%.3f  recall@1=%.3f  recall@3=%.3f", n, rr / Double(n), Double(r1) / Double(n), Double(r3) / Double(n)) }
        var mrr: Double { n == 0 ? 0 : rr / Double(n) }
    }

    nonisolated static func load() throws -> [BankQuestion] {
        try JSONDecoder().decode(BankFile.self, from: Data(contentsOf: AtlasFixture.resourceDir.appendingPathComponent("atlas-bank.json"))).entries
    }

    struct Run { var outcomes: [Outcome] = []; var unresolved: [String: [String]] = [:]; var skipped: [String] = []; var remapped: [String: Int] = [:] }

    nonisolated static func run(engine: SetuEngine, bank: [BankQuestion], weight: Double? = nil, also: Also = .tableAndTitles) async -> Run {
        let have = Set(engine.entries.map(\.id))
        var r = Run()
        for (n, q) in bank.enumerated() {
            if n % 8 == 0 { await Task.yield() }      // the suite is main-actor bound: let the other tests' main-actor work in between, or they starve for the whole grid
            var good = Set<String>()
            for id in q.expected {
                if have.contains(id) { good.insert(id) }
                else if let m = exact[id] ?? near[id], have.contains(m) { good.insert(m); r.remapped[id, default: 0] += 1 }
                else { r.unresolved[id, default: []].append(q.id) }
            }
            if good.isEmpty { r.skipped.append(q.id); continue }
            good = accepted(good.union(q.expected), in: engine.entries, also: also).intersection(Set(engine.entries.map(\.id)))
            let plat: AtlasPlatforms = q.platform == "both" ? .all : q.platform == "ios" ? [.iPhone, .iPad] : .mac     // "both": the question may be about any device
            let res = engine.retrieve(q.q, platform: plat, limit: 10, embeddingWeight: weight)
            let rank = res.hits.firstIndex { good.contains($0.entry.id) }.map { $0 + 1 }
            var o = Outcome(q: q, rank: rank, top: res.hits.first?.entry.id, decision: res.decision, confidence: res.confidence, ratio: res.ratio, intentOK: res.intent.rawValue == q.intent)
            // what the answer rule reads besides confidence and ratio (the same words-versus-title test as SetuEngine.answer), so a threshold choice can be replayed offline
            let detected = IntentDetector.detect(q.q)
            let words = Set(Normalise.words(q.q).filter { !Normalise.stopWords.contains($0) || Synonyms.keyWords.contains($0) || $0 == "show" }.map(Normalise.stem))
            if let t = res.hits.first?.entry { o.covers = !words.isEmpty && words.isSubset(of: Set(Normalise.words(t.title).map(Normalise.stem))); o.topKind = t.kind.rawValue }
            o.intent = res.intent.rawValue; o.hasValue = detected.value != nil; o.rank3 = (rank ?? 99) <= 3
            r.outcomes.append(o)
        }
        return r
    }

    nonisolated static func tagStats(_ outcomes: [Outcome]) -> [(String, Stats)] {
        var by: [String: Stats] = [:]
        for o in outcomes { by["all", default: Stats()].add(o.rank); for t in (o.q.tags.isEmpty ? ["untagged"] : o.q.tags) { by["tag:" + t, default: Stats()].add(o.rank) }; by["intent:" + o.q.intent, default: Stats()].add(o.rank) }
        return by.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    @Test func bankHasTheExpectedShape() throws {
        let bank = try Self.load()
        #expect(bank.count == 511)
        let held = bank.filter { $0.tags.contains("heldout") }.count
        #expect(held >= bank.count / 10)
        #expect(Set(bank.map(\.id)).count == bank.count)
    }

    @Test func gridOfEmbeddingWeightsAndTheReport() async throws {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        let bank = try Self.load()
        let source = AtlasEmbeddings.source ?? "none"
        // Changed: the embeddings are built off the main actor (Sendable values); built inline they held it for seconds in a full run while other main-actor tests waited.
        let entries = AtlasFixture.entries, base = AtlasFixture.engine
        let engine = await Task.detached(priority: .userInitiated) { base.with(embeddings: AtlasEmbeddings.build(entries: entries)) }.value
        var lines: [String] = ["Embedding source on this machine: \(source) (NLEmbedding sentence model installed: \(AtlasEmbeddings.sentence != nil); word vectors installed: \(AtlasEmbeddings.words != nil))", ""]
        lines.append("Weight grid (MRR@10 over answerable questions):")
        var cache: [Also: Run] = [:]
        func runFor(_ a: Also) async -> Run { if let r = cache[a] { return r }; let r = await Self.run(engine: engine, bank: bank, also: a); cache[a] = r; return r }
        var best = (w: 0.0, mrr: -1.0)
        let sweep = ProcessInfo.processInfo.environment["STREAMSETU_PERF"] == "1"      // the weight sweep is report-only (5 full bank runs); the committed weight is always run below
        for w in sweep ? [0.0, 0.25, 0.5, 0.75, 1.0] : [] {
            let run = await Self.run(engine: engine, bank: bank, weight: w)
            var s = Stats(); for o in run.outcomes { s.add(o.rank) }
            lines.append(String(format: "  wEmb=%.2f  ", w) + s.line)
            if s.mrr > best.mrr + 1e-9 { best = (w, s.mrr) }
        }
        if sweep { lines.append("  best weight on this bank: \(best.w) (committed constant Fusion.embeddingWeight = \(Fusion.embeddingWeight))") }

        lines.append(""); lines.append("What the accepted-equivalents rule contributes (committed weight):")
        for also in Also.allCases { var s = Stats(); for o in await runFor(also).outcomes { s.add(o.rank) }; lines.append("  " + also.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0) + s.line) }

        let run = await runFor(.tableAndTitles)
        lines.append(""); lines.append("Bank at committed weight, answerable questions: \(run.outcomes.count) of \(bank.count); skipped (no expected id exists): \(run.skipped.count)")
        for (k, s) in Self.tagStats(run.outcomes) { lines.append("  " + k.padding(toLength: 28, withPad: " ", startingAt: 0) + s.line) }
        let intentOK = Double(run.outcomes.filter(\.intentOK).count) / Double(max(run.outcomes.count, 1))
        for also in Also.allCases {
            let r = await runFor(also)
            var tune = Stats(), held = Stats()
            for o in r.outcomes { if o.q.tags.contains("heldout") { held.add(o.rank) } else { tune.add(o.rank) } }
            let rc = r.outcomes.filter { $0.decision == .confident }, wrong = rc.filter { $0.rank != 1 }.count
            lines.append("Rule [\(also.rawValue)]  tuning set: " + tune.line); lines.append("Rule [\(also.rawValue)]  HELD-OUT:   " + held.line + String(format: "  confident-but-wrong overall %.1f%% (%d of %d confident)", 100 * Double(wrong) / Double(max(rc.count, 1)), wrong, rc.count))
        }
        lines.append(String(format: "Intent accuracy against the bank's guessed intents: %.3f", intentOK))
        let conf = run.outcomes.filter { $0.decision == .confident }
        let wrongConf = conf.filter { $0.rank != 1 }
        lines.append("Decisions: confident \(conf.count), ambiguous \(run.outcomes.filter { $0.decision == .ambiguous }.count), weak \(run.outcomes.filter { $0.decision == .weak }.count); confident-but-wrong-top1: \(wrongConf.count) (\(String(format: "%.1f", 100 * Double(wrongConf.count) / Double(max(conf.count, 1))))% of confident)")
        lines.append("Confident but wrong (tuning questions only):")
        for o in wrongConf where !o.q.tags.contains("heldout") { lines.append(String(format: "  %@ [%@] expected %@ got %@ conf %.2f ratio %.2f", o.q.id, o.q.q, o.q.expected.joined(separator: "|"), o.top ?? "-", o.confidence, o.ratio)) }
        let correct = run.outcomes.filter { $0.rank == 1 }.map(\.confidence).sorted()
        if !correct.isEmpty { lines.append(String(format: "Confidence of correct top1: p20=%.3f p50=%.3f; thresholds in code: confident >= %.2f, ratio >= %.2f", correct[correct.count / 5], correct[correct.count / 2], SetuEngine.confidentThreshold, SetuEngine.ratioThreshold)) }

        lines.append("Threshold sweep (confident = confidence >= T and ratio >= 1.25): T, confident, wrong top1 among them")
        for t in stride(from: 0.4, through: 1.0, by: 0.1) {
            let c = run.outcomes.filter { $0.confidence >= t && $0.ratio >= SetuEngine.ratioThreshold }
            lines.append(String(format: "  T=%.1f  confident %3d  wrong %2d (%.1f%%)", t, c.count, c.filter { $0.rank != 1 }.count, 100 * Double(c.filter { $0.rank != 1 }.count) / Double(max(c.count, 1))))
        }
        lines.append(""); lines.append("Ids remapped to real entries (count of questions): ")
        for (k, v) in run.remapped.sorted(by: { $0.key < $1.key }) { lines.append("  \(k) -> \(Self.exact[k] ?? Self.near[k] ?? "?") [\(Self.exact[k] != nil ? "same thing" : "judgement")] x\(v)") }
        lines.append(""); lines.append("Bank ids that do not exist in the imported data (\(run.unresolved.count) ids, \(run.skipped.count) questions skipped):")
        for (k, v) in run.unresolved.sorted(by: { $0.key < $1.key }) { lines.append("  \(k)  (\(v.count) questions: \(v.prefix(4).joined(separator: ", "))\(v.count > 4 ? ", ..." : ""))") }
        lines.append(""); lines.append("Misses (answerable, not in top 10 or not first), first 60:")
        for o in run.outcomes.filter({ $0.rank != 1 && !$0.q.tags.contains("heldout") }).prefix(80) { lines.append("  \(o.q.id) [\(o.q.q)] expected \(o.q.expected.joined(separator: "|")) got \(o.top ?? "-") rank \(o.rank.map(String.init) ?? "none")") }

        // What the person is actually shown: a single answer (decision .confident) or choices. "Answered wrong" = the answer given first is not an accepted entry. Tuning and held-out are reported apart.
        do {
            let have = Set(engine.entries.map(\.id))
            var tune = (answered: 0, wrong: 0, n: 0, top3: 0), held = (answered: 0, wrong: 0, n: 0, top3: 0)
            for (n, q) in bank.enumerated() {
                if n % 8 == 0 { await Task.yield() }
                var good = Set<String>()
                for id in q.expected { if have.contains(id) { good.insert(id) } else if let m = Self.exact[id] ?? Self.near[id], have.contains(m) { good.insert(m) } }
                if good.isEmpty { continue }
                good = Self.accepted(good.union(q.expected), in: engine.entries).intersection(have)
                let plat: AtlasPlatforms = q.platform == "both" ? .all : q.platform == "ios" ? [.iPhone, .iPad] : .mac
                var conv = AtlasConversation()
                let a = engine.answer(q.q, conversation: &conv, platform: plat)
                let isHeld = q.tags.contains("heldout")
                var t = isHeld ? held : tune
                t.n += 1
                if a.entryIDs.prefix(3).contains(where: good.contains) { t.top3 += 1 }
                if a.decision == .confident, !a.entryIDs.isEmpty { t.answered += 1; if !good.contains(a.entryIDs[0]) { t.wrong += 1 } }
                if isHeld { held = t } else { tune = t }
            }
            for (name, t) in [("tuning", tune), ("HELD-OUT", held)] {
                lines.append(String(format: "Answer level [%@]: questions %d, answered with one answer %d, wrong first answer %d (%.1f%% of answered, %.1f%% of all questions); right entry in the first 3 shown %.3f", name, t.n, t.answered, t.wrong, 100 * Double(t.wrong) / Double(max(t.answered, 1)), 100 * Double(t.wrong) / Double(max(t.n, 1)), Double(t.top3) / Double(max(t.n, 1))))
            }
        }
        // one row per question for offline calibration of the abstain rule (tuning questions and held-out questions are marked)
        var tsv = ["id\theld\trank\tconf\tratio\tdecision\tintent\ttopKind\thasValue\tcovers"]
        for o in run.outcomes { tsv.append([o.q.id, o.q.tags.contains("heldout") ? "1" : "0", o.rank.map(String.init) ?? "0", String(format: "%.4f", o.confidence), String(format: "%.4f", o.ratio), "\(o.decision)", o.intent, o.topKind, o.hasValue ? "1" : "0", o.covers ? "1" : "0"].joined(separator: "\t")) }
        try? FileManager.default.createDirectory(at: AtlasFixture.reportDir, withIntermediateDirectories: true)
        try? tsv.joined(separator: "\n").write(to: AtlasFixture.reportDir.appendingPathComponent("atlas-bank-features.tsv"), atomically: true, encoding: .utf8)
        let text = lines.joined(separator: "\n")
        print(text)
        try? FileManager.default.createDirectory(at: AtlasFixture.reportDir, withIntermediateDirectories: true)
        try? text.write(to: AtlasFixture.reportDir.appendingPathComponent("atlas-bank-report.txt"), atomically: true, encoding: .utf8)
        #expect(run.outcomes.count > 100)
    }
}
