import Testing
import Foundation
@testable import REDDY

/// A scripted model. Nothing here talks to a real model: the point is that whatever a model says, the answer stays the engine's or a validated pick.
final class MockAtlasLanguageModel: AtlasLanguageModel, @unchecked Sendable {
    enum Script { case pick(String), draft(AtlasQueryDraft), fail, hang, overlap, rateLimited }
    var script: Script
    var remote: Bool
    var phrasing: ((AtlasFacts) -> AtlasPhrasing)?
    private(set) var interpretCalls = 0, phraseCalls = 0
    init(_ s: Script, remote: Bool = false) { script = s; self.remote = remote }
    var name: String { "Mock" }
    var isRemote: Bool { remote }
    func interpret(_ text: String, candidates: [AtlasCandidate]) async throws -> AtlasQueryDraft {
        interpretCalls += 1
        switch script {
        case .pick(let id): return AtlasQueryDraft(pick: id)
        case .draft(let d): return d
        case .fail: throw AtlasModelError.unavailable
        case .rateLimited: throw AtlasModelError.rateLimited
        case .hang: try await Task.sleep(nanoseconds: 5_000_000_000); return AtlasQueryDraft()
        case .overlap:
            // a stand-in for a reasonable model: the candidate whose words overlap the question most
            let q = Set(Normalise.words(text))
            let best = candidates.max { Set(Normalise.words($0.title + " " + $0.summary)).intersection(q).count < Set(Normalise.words($1.title + " " + $1.summary)).intersection(q).count }
            return AtlasQueryDraft(pick: best?.id)
        }
    }
    func phrase(_ facts: AtlasFacts, tone: AtlasTone) async throws -> AtlasPhrasing {
        phraseCalls += 1
        return phrasing?(facts) ?? AtlasPhrasing(text: facts.text, mentions: [facts.title])
    }
}

@MainActor @Suite("Atlas: optional model layer", .serialized) struct AtlasModelTests {
    let engine = AtlasFixture.engine
    func accepts(_ e: AtlasEntry, _ v: String) -> Bool { ["on", "off"].contains(v.lowercased()) }
    func run(_ q: String, _ m: (any AtlasLanguageModel)?, _ o0: AtlasModelOptions = AtlasModelOptions(), on: @escaping @Sendable () -> Bool = { true }) async -> AtlasModelResult {
        var o = o0; if o.cooldown === AtlasModelCooldown.shared { o.cooldown = AtlasModelCooldown() }      // each test has its own cooldown
        return await AtlasModelAssist.resolve(q, engine: engine, conversation: AtlasConversation(), platform: .mac, appStore: false, model: m, options: o, isStillOn: on, accepts: accepts)
    }
    /// A question the engine cannot place on its own.
    let vague = "that thing where the picture looks all blocky sometimes"
    func base(_ q: String) -> AtlasAnswer { var c = AtlasConversation(); return engine.answer(q, conversation: &c, platform: .mac) }

    @Test func validatorDropsEverythingThatIsNotAnEngineCandidate() {
        let cands = Array(AtlasFixture.entries.prefix(5))
        let ok = AtlasModelValidator.validate(AtlasQueryDraft(pick: cands[2].id, intent: "where-is"), candidates: cands, accepts: accepts)
        #expect(ok.entryID == cands[2].id && ok.intent == .whereIs && ok.rejected.isEmpty)
        for bad in ["setting.doesNotExist", "recipe.deleteEverything", "", "screen.tab.liveTV; drop"] {
            if bad.isEmpty { continue }
            let v = AtlasModelValidator.validate(AtlasQueryDraft(pick: bad), candidates: cands, accepts: accepts)
            #expect(v.entryID == nil && !v.rejected.isEmpty)
        }
        let v = AtlasModelValidator.validate(AtlasQueryDraft(pick: cands[0].id, intent: "format-disk", value: "maybe", platform: "windows", rewrite: String(repeating: "x", count: 300)), candidates: cands, accepts: accepts)
        #expect(v.intent == nil && v.value == nil && v.platform == nil && v.rewrite == nil && v.rejected.count == 4)
        #expect(AtlasModelValidator.validate(AtlasQueryDraft(intent: "chat"), candidates: cands, accepts: accepts).intent == nil)
    }

    @Test func aModelProposedChangeNeverReachesAGuideOnlyOrNonChangeableEntry() {
        let guide = AtlasFixture.entries.filter(\.guideOnly)
        #expect(!guide.isEmpty)
        for e in guide {
            let forged = AtlasAnswer(text: "x", entryIDs: [e.id], actions: [AtlasAction(kind: .changeIt, entryID: e.id, value: "off", label: "Change it")], decision: .confident, intent: .setValue)
            #expect(AtlasModelValidator.sanitise(forged, allowed: [e], kids: false, accepts: { _, _ in true }).actions.isEmpty, "\(e.id)")
        }
        // the value check applies too, and an action naming an entry that was not offered is dropped
        let live = AtlasFixture.entries.first { $0.mayPropose }!
        let a = AtlasAnswer(text: "x", entryIDs: [live.id], actions: [AtlasAction(kind: .changeIt, entryID: live.id, value: "nonsense", label: "c"), AtlasAction(kind: .openThis, entryID: "made.up", label: "o")], decision: .confident, intent: .setValue)
        #expect(AtlasModelValidator.sanitise(a, allowed: [live], kids: false, accepts: accepts).actions.isEmpty)
        #expect(AtlasModelValidator.sanitise(a, allowed: [live], kids: true, accepts: { _, _ in true }).actions.isEmpty)
    }

    @Test func aValidPickIsUsedOnlyWhenTheEngineWasNotConfident() async throws {
        #expect(base(vague).decision != .confident)
        let want = engine.retrieve(vague, platform: .mac, limit: 8).hits.map(\.entry)[1].id
        let m = MockAtlasLanguageModel(.pick(want))
        let r = await run(vague, m)
        #expect(r.assisted && r.answer.entryIDs == [want] && m.interpretCalls == 1)
        // a confident question never asks the model (unless the person opted in, and then only to rephrase)
        let sure = "where is hardware decoding"
        #expect(base(sure).decision == .confident)
        let m2 = MockAtlasLanguageModel(.pick(want))
        let r2 = await run(sure, m2)
        #expect(!r2.assisted && m2.interpretCalls == 0 && r2.answer.text == base(sure).text)
    }

    @Test func everyFailureLeavesTheDeterministicAnswer() async {
        let expected = base(vague)
        let hang = MockAtlasLanguageModel(.hang)
        var quick = AtlasModelOptions(); quick.timeout = 0.2
        for (m, o) in [(MockAtlasLanguageModel(.fail), AtlasModelOptions()), (hang, quick), (MockAtlasLanguageModel(.pick("setting.nope")), AtlasModelOptions()), (MockAtlasLanguageModel(.draft(AtlasQueryDraft())), AtlasModelOptions())] as [(MockAtlasLanguageModel, AtlasModelOptions)] {
            let r = await run(vague, m, o)
            #expect(!r.assisted && r.answer.text == expected.text && r.answer.entryIDs == expected.entryIDs && r.answer.decision == expected.decision)
        }
        let none = await run(vague, nil)
        #expect(none.answer.text == expected.text)
    }

    @Test func turningTheModelOffMidRunFallsBackToTheEngine() async {
        let want = engine.retrieve(vague, platform: .mac, limit: 8).hits.map(\.entry)[1].id
        final class Flag: @unchecked Sendable { var on = true }
        let flag = Flag()
        let m = MockAtlasLanguageModel(.pick(want))
        let before = await run(vague, m, on: { flag.on })
        #expect(before.assisted)
        // the person switches the model off while the question is in flight: the answer arrives after the switch and is dropped
        final class Slow: AtlasLanguageModel, @unchecked Sendable {
            let flag: Flag; let id: String
            init(_ f: Flag, _ id: String) { flag = f; self.id = id }
            var name: String { "Slow" }; var isRemote: Bool { false }
            func interpret(_ text: String, candidates: [AtlasCandidate]) async throws -> AtlasQueryDraft { flag.on = false; return AtlasQueryDraft(pick: id) }
            func phrase(_ facts: AtlasFacts, tone: AtlasTone) async throws -> AtlasPhrasing { AtlasPhrasing(text: facts.text) }
        }
        flag.on = true
        let mid = await run(vague, Slow(flag, want), on: { flag.on })
        #expect(!mid.assisted && mid.answer.text == base(vague).text)
        let off = await run(vague, m, on: { false })
        #expect(!off.assisted && off.answer.text == base(vague).text)
    }

    @Test func kidsAndRemotePrivacyGatesStopTheCall() async {
        let want = engine.retrieve(vague, platform: .mac, limit: 8).hits.map(\.entry)[1].id
        var kids = AtlasModelOptions(); kids.kids = true
        let m = MockAtlasLanguageModel(.pick(want))
        let k = await run(vague, m, kids)
        #expect(!k.assisted && m.interpretCalls == 0)
        let remote = MockAtlasLanguageModel(.pick(want), remote: true)
        let blocked = await run(vague, remote)
        #expect(!blocked.assisted && remote.interpretCalls == 0)
        var allowed = AtlasModelOptions(); allowed.remoteAllowed = true
        let ok = await run(vague, remote, allowed)
        #expect(ok.assisted && remote.interpretCalls == 1)
    }

    @Test func aPickedGuideOnlyEntryCarriesNoChangeButton() async {
        let e = AtlasFixture.entries.first { $0.guideOnly && $0.kind == .setting }!
        var o = AtlasModelOptions(); o.remoteAllowed = true
        let r = await AtlasModelAssist.resolve("turn off the lock thing", engine: engine, conversation: AtlasConversation(), platform: .mac, appStore: false,
                                               model: MockAtlasLanguageModel(.draft(AtlasQueryDraft(pick: e.id, intent: "set-value", value: "off"))), options: o, accepts: { _, _ in true })
        #expect(!r.answer.actions.contains { $0.kind == .changeIt })
    }

    @Test func phrasingIsAcceptedOnlyWhenItAddsNothing() {
        let f = AtlasFacts(title: "Hardware decoding", text: "Hardware decoding is in Settings > Playback. It is on.", path: ["Settings", "Playback"], options: ["On", "Off"], current: "on")
        func ok(_ t: String, _ m: [String] = []) -> Bool { AtlasModelValidator.validate(AtlasPhrasing(text: t, mentions: m), facts: f) != nil }
        #expect(ok("You will find Hardware decoding in Settings > Playback, and it is on.", ["Hardware decoding"]))
        #expect(!ok("Hardware decoding is in Settings > Playback. Also try Smooth Motion."))     // a name that is not in the facts
        #expect(!ok("Hardware decoding is in Settings > Playback and uses 4 cores."))              // a number that is not in the facts
        #expect(!ok("Hardware decoding is in Settings > Playback.", ["Turbo mode"]))               // a mention that is not in the facts
        #expect(!ok("See https://example.com for Hardware decoding."))
        #expect(!ok("As an AI I cannot say."))
        #expect(!ok(""))
        #expect(!ok(String(repeating: "Hardware decoding is on. ", count: 10)))
        #expect(!ok("Press ⌘K to open Hardware decoding."))
    }

    @Test func friendlyWordingReplacesTheTextOnlyWhenItValidates() async {
        var o = AtlasModelOptions(); o.friendly = true; o.optedIn = true
        let sure = "where is hardware decoding"
        let m = MockAtlasLanguageModel(.fail)
        m.phrasing = { AtlasPhrasing(text: "Sure! " + $0.text, mentions: [$0.title]) }
        let r = await run(sure, m, o)
        #expect(r.assisted && r.answer.text.hasPrefix("Sure!") && m.interpretCalls == 0)
        m.phrasing = { AtlasPhrasing(text: $0.text + " It also changes Quantum Sync.", mentions: []) }
        let r2 = await run(sure, m, o)
        #expect(!r2.assisted && r2.answer.text == base(sure).text)
    }

    @Test func promptParserMapsNumbersToCandidatesAndNeverTrustsIds() {
        let c = [AtlasCandidate(id: "a", title: "A", path: "", summary: ""), AtlasCandidate(id: "b", title: "B", path: "", summary: "")]
        #expect(AtlasModelPrompt.parseDraft("```json\n{\"pick\": 2, \"intent\": \"where-is\"}\n```", candidates: c)?.pick == "b")
        #expect(AtlasModelPrompt.parseDraft("{\"pick\": 9}", candidates: c)?.pick == nil)
        #expect(AtlasModelPrompt.parseDraft("{\"pick\": 0}", candidates: c)?.pick == nil)
        #expect(AtlasModelPrompt.parseDraft("not json", candidates: c) == nil)
    }

    /// With a stand-in model, how often does the first reply pass the validator, and what does the pipeline change for the questions the engine was unsure about. Not a measure of a real model.
    @Test func bankRunWithAMockModelRecordsTheFirstTryPassRate() async throws {
        await HeavyTestSlot.shared.acquire(); defer { Task { await HeavyTestSlot.shared.release() } }      // one heavy test at a time (see HeavyTestSlot)
        let bank = try AtlasBankTests.load()
        let m = MockAtlasLanguageModel(.overlap)
        var asked = 0, passed = 0, phrased = 0, phrasePassed = 0, changedTop = 0, improved = 0, worsened = 0
        let eng = AtlasFixture.engine
        let have = Set(eng.entries.map(\.id))
        for (n, q) in bank.enumerated() {
            if n % 8 == 0 { await Task.yield() }
            let plat: AtlasPlatforms = q.platform == "ios" ? [.iPhone, .iPad] : .mac
            let r = eng.retrieve(q.q, platform: plat, limit: 8)
            if r.decision == .confident { continue }
            let found = r.hits.map(\.entry)
            let cands = found.map { AtlasCandidate(id: $0.id, title: $0.title, path: $0.path.joined(separator: " > "), summary: $0.summary) }
            guard let d = try? await m.interpret(q.q, candidates: cands) else { continue }
            asked += 1
            if AtlasModelValidator.validate(d, candidates: found, accepts: { _, _ in false }).entryID != nil { passed += 1 }
            let good = AtlasBankTests.accepted(Set(q.expected.compactMap { have.contains($0) ? $0 : (AtlasBankTests.exact[$0] ?? AtlasBankTests.near[$0]) }), in: eng.entries)
            if let p = d.pick, p != found.first?.id { changedTop += 1; let was = good.contains(found.first?.id ?? ""), now = good.contains(p); if now && !was { improved += 1 }; if was && !now { worsened += 1 } }
            if let e = found.first {
                var c = AtlasConversation()
                let a = eng.answer(q.q, conversation: &c, platform: plat)
                let f = AtlasFacts(title: e.title, text: a.text, path: e.path, options: e.value?.options ?? [], shortcut: e.shortcut)
                phrased += 1
                let p = AtlasPhrasing(text: "Here you go. " + a.text, mentions: [e.title])
                if AtlasModelValidator.validate(p, facts: f) != nil { phrasePassed += 1 }
            }
        }
        // The conservative gate in action: the real orchestrator, with the stand-in model, against the engine alone.
        var gated = 0, gBetter = 0, gWorse = 0
        for (n, q) in bank.enumerated() {
            if n % 8 == 0 { await Task.yield() }
            let plat: AtlasPlatforms = q.platform == "ios" ? [.iPhone, .iPad] : .mac
            var o = AtlasModelOptions(); o.cooldown = AtlasModelCooldown()
            var c0 = AtlasConversation()
            let baseTop = eng.answer(q.q, conversation: &c0, platform: plat).entryIDs.first
            let r = await AtlasModelAssist.resolve(q.q, engine: eng, conversation: AtlasConversation(), platform: plat, appStore: false, model: m, options: o)
            guard r.assisted, let top = r.answer.entryIDs.first, top != baseTop else { continue }
            gated += 1
            let good = AtlasBankTests.accepted(Set(q.expected.compactMap { have.contains($0) ? $0 : (AtlasBankTests.exact[$0] ?? AtlasBankTests.near[$0]) }), in: eng.entries)
            let was = good.contains(baseTop ?? ""), now = good.contains(top)
            if now && !was { gBetter += 1 }; if was && !now { gWorse += 1 }
        }
        let gatedLine = "Conservative gate (margin below \(SetuEngine.leadRatio), pick in top 5): the stand-in model changed the engine's top answer for \(gated) questions: better \(gBetter), worse \(gWorse)."
        print(gatedLine)
        let line = "Mock-model bank run: questions the engine was unsure about \(asked); pick passed the validator first try \(passed) (\(String(format: "%.1f", 100 * Double(passed) / Double(max(asked, 1))))%); "
            + "picks that differ from the engine's top \(changedTop), of which better \(improved), worse \(worsened); phrasing first-try pass (a prefix-only rewording) \(phrasePassed)/\(phrased). A stand-in model, not a real one."
        print(line)
        try? FileManager.default.createDirectory(at: AtlasFixture.reportDir, withIntermediateDirectories: true)
        try? (line + "\n" + gatedLine).write(to: AtlasFixture.reportDir.appendingPathComponent("atlas-model-report.txt"), atomically: true, encoding: .utf8)
        #expect(asked > 20 && Double(passed) >= 0.95 * Double(asked))
    }

    @Test func theRequestIsTrimmedToTheWindowAndOnlyEnglishGoesToTheModel() {
        let many = (0..<60).map { AtlasCandidate(id: "x\($0)", title: "Title \($0)", path: "A > B", summary: String(repeating: "word ", count: 80)) }
        let t = AtlasModelBudget.trim("how do i", candidates: many)
        #expect(t.candidates.count < many.count && t.candidates.first?.id == "x0" && t.used <= AtlasModelBudget.window - AtlasModelBudget.reservedForAnswer)
        let tiny = AtlasModelBudget.trim("how do i", candidates: many, window: 800)
        #expect(tiny.used <= 800)
        #expect(AtlasModelBudget.isEnglish("how do i turn on subtitles") && !AtlasModelBudget.isEnglish("सबटाइटल कैसे चालू करें") && !AtlasModelBudget.isEnglish("సబ్ టైటిల్స్ ఎలా"))
    }

    @Test func statusTextIsCalm() {
        #expect(AtlasModelStatus.chip(appleReady: true, why: "", providerReady: false, providerTitle: "") == "Apple Intelligence")
        #expect(AtlasModelStatus.chip(appleReady: false, why: "Apple Intelligence is still getting ready. Try again soon.", providerReady: false, providerTitle: "").contains("getting ready"))
        #expect(AtlasModelStatus.chip(appleReady: false, why: "This device does not support Apple Intelligence.", providerReady: false, providerTitle: "") == "On device")
        #expect(AtlasModelStatus.chip(appleReady: false, why: "", providerReady: true, providerTitle: "Google Gemini") == "Google Gemini")
    }

    @Test func aNonEnglishQuestionNeverReachesTheModel() async {
        let m = MockAtlasLanguageModel(.pick("setting.theme"))
        let r = await run("सबटाइटल कैसे चालू करें", m)
        #expect(!r.assisted && m.interpretCalls == 0)
    }

    @Test(arguments: [("", AtlasModelAvailability.available), ("Turn on Apple Intelligence in System Settings.", .notEnabled), ("Apple Intelligence is still getting ready. Try again soon.", .modelNotReady),
                      ("This device does not support Apple Intelligence.", .deviceNotEligible), ("Apple Intelligence needs macOS, iOS or iPadOS 26 or newer.", .unsupportedOS)])
    func eachAvailabilityStateHasCalmWordsAndOnlyAvailableIsUsed(_ c: (String, AtlasModelAvailability)) async {
        #expect(AtlasModelAvailability.from(ok: c.1 == .available, why: c.0) == c.1)
        #expect(!c.1.chip.lowercased().contains("error") && !c.1.chip.isEmpty)
        let want = engine.retrieve(vague, platform: .mac, limit: 8).hits.map(\.entry)[1].id
        let m = MockAtlasLanguageModel(.pick(want))
        var o = AtlasModelOptions(); o.availability = c.1; o.cooldown = AtlasModelCooldown()
        let r = await run(vague, m, o)
        #expect(m.interpretCalls == (c.1 == .available ? 1 : 0))
        if c.1 != .available { #expect(!r.assisted && r.answer.text == base(vague).text) }
    }

    @Test func aRateLimitStartsACooldownAndNoRetryStormFollows() async {
        let m = MockAtlasLanguageModel(.rateLimited)
        var o = AtlasModelOptions(); o.cooldown = AtlasModelCooldown()
        let first = await run(vague, m, o)
        #expect(!first.assisted && m.interpretCalls == 1 && o.cooldown.isCooling())
        for _ in 0..<5 { _ = await run(vague, m, o) }
        #expect(m.interpretCalls == 1)                       // the engine answered the rest alone
        o.cooldown.reset()
        _ = await run(vague, m, o)
        #expect(m.interpretCalls == 2)
    }

    @Test func aTimeoutCoolsDownToo() async {
        var o = AtlasModelOptions(); o.timeout = 0.1; o.cooldown = AtlasModelCooldown()
        let m = MockAtlasLanguageModel(.hang)
        _ = await run(vague, m, o)
        #expect(o.cooldown.isCooling())
    }

    @Test func aCancelledQuestionNeverReturnsAModelAnswer() async {
        let want = engine.retrieve(vague, platform: .mac, limit: 8).hits.map(\.entry)[1].id
        let m = MockAtlasLanguageModel(.pick(want))
        let t = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)      // cancelled while "waiting"
            return await self.run(self.vague, m)
        }
        t.cancel()
        let r = await t.value
        #expect(!r.assisted && r.answer.text == base(vague).text)
    }

    @Test func theModelCannotOverrideAClearLeadOrPickOutsideTheTopCandidates() async {
        // a pick beyond the engine's top five is dropped
        let hits = engine.retrieve(vague, platform: .mac, limit: 8).hits.map(\.entry)
        if hits.count >= 8 {
            let far = await run(vague, MockAtlasLanguageModel(.pick(hits[7].id)))
            #expect(!far.assisted)
        }
        // an answer the engine gave with a clear lead stands whatever the model says
        let clear = "where is hardware decoding"
        let m = MockAtlasLanguageModel(.pick(hits[1].id))
        let r = await run(clear, m)
        #expect(!r.assisted && m.interpretCalls == 0 && r.answer.text == base(clear).text)
    }

    @Test func theDisambiguationQuestionNamesTheCandidates() {
        let es = Array(AtlasFixture.entries.prefix(3))
        let a = Compose.ambiguous(es, intent: .whereIs)
        #expect(a.text.hasPrefix("Did you mean ") && es.allSatisfy { a.text.contains($0.title) } && a.actions.count == 3)
        #expect(Compose.question([]) == "Did you mean one of these?")
    }

    @Test func personalisedWordingMayUseOnlyValuesTheAppReported() {
        let f = AtlasFacts(title: "Proxy", text: "Proxy is in Settings > Privacy.", path: ["Settings", "Privacy"], current: "on", others: ["Hardware decoding: off"])
        func ok(_ t: String) -> Bool { AtlasModelValidator.validate(AtlasPhrasing(text: t, mentions: []), facts: f) != nil }
        #expect(ok("Your proxy is on, and Hardware decoding is off."))
        #expect(!ok("Your proxy is on, and Smooth Motion is off."))        // a setting the app did not report
        #expect(AtlasModelPrompt.phrasePrompt(f, tone: .friendly).contains("Hardware decoding: off"))
    }

    @Test func aSmallWindowTrimsMoreAndTheDefaultIsTheSmallestKnown() {
        struct M: AtlasLanguageModel { var name: String { "m" }; var isRemote: Bool { false }
            func interpret(_ t: String, candidates: [AtlasCandidate]) async throws -> AtlasQueryDraft { AtlasQueryDraft() }
            func phrase(_ f: AtlasFacts, tone: AtlasTone) async throws -> AtlasPhrasing { AtlasPhrasing(text: "") } }
        #expect(M().contextWindow == 4096)
        let many = (0..<30).map { AtlasCandidate(id: "x\($0)", title: "T\($0)", path: "A > B", summary: String(repeating: "word ", count: 40)) }
        let big = AtlasModelBudget.trim("q", candidates: many, window: 8192), small = AtlasModelBudget.trim("q", candidates: many, window: 1200)
        #expect(small.candidates.count < big.candidates.count && small.used <= 1200)
    }
}
