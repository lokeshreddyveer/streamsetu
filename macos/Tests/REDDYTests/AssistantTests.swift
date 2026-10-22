import Testing
import Foundation
@testable import REDDY

/// Answers each request with the next scripted body, and keeps what was sent.
final class ScriptedWeb: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String]
    private(set) var requests: [URLRequest] = []
    init(_ b: [String]) { bodies = b }
    var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { [self] r in
            let b = lock.withLock { requests.append(r); return bodies.isEmpty ? "{}" : bodies.removeFirst() }
            return (Data(b.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    func sent(_ i: Int) -> [String: Any] { (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: Any] ?? [:] }
}

@Suite("Assistant: what the person is shown") struct AssistantTextTests {
    @Test func theBrokenAppleAnswerFromTheScreenshot() {
        #expect(AssistantText.clean(#"{"tool":"say":"Nothing in the library matches. Want to search again?"}"#) == "Nothing in the library matches. Want to search again?")
    }
    @Test func theTwoObjectAnswerFromOllamaCloud() {
        let raw = "{\n  \"tool\": \"web\",\n  \"query\": \"Nani actor\"\n}\n{\n  \"say\": \"Nani is an Indian actor who works mainly in Telugu cinema.\"\n}"
        #expect(AssistantText.clean(raw) == "Nani is an Indian actor who works mainly in Telugu cinema.")
    }
    @Test func aToolCallWithNothingToSayShowsNothingRaw() {
        #expect(AssistantText.clean(#"{"tool": "find", "query": "x"}"#) == "")
    }
    @Test func plainWordsAndFencesAreKept() {
        #expect(AssistantText.clean("Just words.") == "Just words.")
        #expect(AssistantText.clean("```json\n{\"say\": \"Hi\"}\n```") == "Hi")
        #expect(AssistantText.clean("Assistant: Hello there") == "Hello there")
    }
    @Test func bracesInsideSentencesSurvive() { #expect(AssistantText.clean("Use {curly} braces sparingly.") == "Use {curly} braces sparingly.") }
}

@Suite("Assistant: each provider's tool calling") struct AssistantProviderTests {
    private let tool = AITool(name: "find_setting", help: "Look up", params: [AIToolParam(name: "query", kind: .string, help: "topic")])
    private func client(_ p: AIProvider, _ web: ScriptedWeb) -> AIClient { var c = AIClient(config: AIConfig(provider: p, model: "", base: "http://127.0.0.1:11434", key: "K")); c.transport = web.transport; return c }
    private let q = [AIMessage(role: .user, text: "subtitles?")]

    @Test func geminiSendsDeclarationsAndReadsAFunctionCall() async throws {
        let web = ScriptedWeb([#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"find_setting","args":{"query":"subtitles"}}}]}}]}"#])
        let m = try await client(.gemini, web).converse(system: "S", messages: q, tools: [tool])
        #expect(m.calls.first?.name == "find_setting"); #expect(m.calls.first?.args["query"]?.text == "subtitles")
        let decl = (((web.sent(0)["tools"] as? [[String: Any]])?.first?["function_declarations"]) as? [[String: Any]])?.first
        #expect(decl?["name"] as? String == "find_setting")
        #expect(web.requests[0].value(forHTTPHeaderField: "x-goog-api-key") == "K")
    }

    @Test func geminiGetsItsOwnPartsBackAndTheToolResultAsAFunctionResponse() async throws {
        let web = ScriptedWeb([#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"find_setting","args":{"query":"x"}},"thoughtSignature":"SIG"}]}}]}"#, #"{"candidates":[{"content":{"parts":[{"text":"Done"}]}}]}"#])
        let c = client(.gemini, web)
        let first = try await c.converse(system: "S", messages: q, tools: [tool])
        let call = first.calls[0]
        _ = try await c.converse(system: "S", messages: q + [first, AIMessage(role: .tool, results: [(call.id, call.name, "RESULT")])], tools: [tool])
        let contents = web.sent(1)["contents"] as? [[String: Any]] ?? []
        #expect(contents.count == 3)
        #expect((contents[1]["parts"] as? [[String: Any]])?.first?["thoughtSignature"] as? String == "SIG")       // the model's own turn, unchanged
        #expect(((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])?["name"] as? String == "find_setting")
    }

    @Test func openAICompatibleProvidersReadStringArgumentsAndAnswerWithToolMessages() async throws {
        for p in [AIProvider.openAI, .groq, .nvidia, .openRouter] {
            let web = ScriptedWeb([#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"find_setting","arguments":"{\"query\":\"subs\"}"}}]}}]}"#, #"{"choices":[{"message":{"content":"ok"}}]}"#])
            let c = client(p, web)
            let t = try await c.converse(system: "S", messages: q, tools: [tool])
            #expect(t.calls.first?.args["query"]?.text == "subs", "\(p)")
            _ = try await c.converse(system: "S", messages: q + [t, AIMessage(role: .tool, results: [("c1", "find_setting", "R")])], tools: [tool])
            let msgs = web.sent(1)["messages"] as? [[String: Any]] ?? []
            #expect(msgs.last?["role"] as? String == "tool"); #expect(msgs.last?["tool_call_id"] as? String == "c1")
            #expect(web.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer K")
        }
    }

    @Test func claudeUsesToolUseAndToolResultBlocks() async throws {
        let web = ScriptedWeb([#"{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"tu1","name":"find_setting","input":{"query":"subs"}}]}"#, #"{"content":[{"type":"text","text":"ok"}]}"#])
        let c = client(.claude, web)
        let t = try await c.converse(system: "S", messages: q, tools: [tool])
        #expect(t.calls.first?.id == "tu1"); #expect(t.text == "Let me look.")
        #expect(((web.sent(0)["tools"] as? [[String: Any]])?.first?["input_schema"]) != nil)
        _ = try await c.converse(system: "S", messages: q + [t, AIMessage(role: .tool, results: [("tu1", "find_setting", "R")])], tools: [tool])
        let last = (web.sent(1)["messages"] as? [[String: Any]])?.last
        #expect(last?["role"] as? String == "user")
        #expect(((last?["content"] as? [[String: Any]])?.first?["type"] as? String) == "tool_result")
    }

    @Test func ollamaReadsObjectArguments() async throws {
        for p in [AIProvider.ollama, .ollamaCloud] {
            let web = ScriptedWeb([#"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"find_setting","arguments":{"query":"subs"}}}]}}"#])
            let t = try await client(p, web).converse(system: "S", messages: q, tools: [tool])
            #expect(t.calls.first?.args["query"]?.text == "subs", "\(p)")
            #expect(web.requests[0].url?.path == "/api/chat")
        }
    }

    @Test func aMissingAnswerIsAnErrorNotRawText() async {
        let web = ScriptedWeb([#"{"choices":[{"message":{"content":""}}]}"#])
        await #expect(throws: AIError.self) { _ = try await client(.openAI, web).converse(system: "S", messages: q, tools: [tool]) }
    }
}

@MainActor @Suite("Assistant: the whole conversation") struct AssistantConversationTests {
    private func rig() throws -> (AppContainer, AppSettings) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-as-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        return (c, c.settings)
    }
    private func gemini(_ web: ScriptedWeb) -> AIClient { var c = AIClient(config: AIConfig(provider: .gemini, model: "", base: "", key: "K")); c.transport = web.transport; return c }
    private func call(_ n: String, _ args: String) -> String { #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"\#(n)","args":\#(args)}}]}}]}"# }
    private func say(_ t: String) -> String { #"{"candidates":[{"content":{"parts":[{"text":"\#(t)"}]}}]}"# }

    @Test func aSettingChangeIsFoundThenOfferedAndOnlyChangesWhenTapped() async throws {
        let (c, s) = try rig(); s.subtitlesByDefault = false
        let web = ScriptedWeb([call("find_setting", #"{"query":"subtitles by default"}"#), call("change_setting", #"{"id":"subtitlesByDefault","value":"on"}"#), say("Tap the button to turn them on.")])
        let r = try await AssistantAgent.run(history: [(true, "turn on subtitles by default")], context: nil, client: gemini(web), toolbox: AssistantToolbox(container: c))
        #expect(r.say == "Tap the button to turn them on.")
        #expect(r.proposals.count == 1)
        #expect(s.subtitlesByDefault == false, "nothing changes until the person taps")
        // the model was shown the real setting, with its current value and where it is
        let toolTurn = (web.sent(1)["contents"] as? [[String: Any]])?.last
        let shown = ((toolTurn?["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])?["response"] as? [String: Any]
        #expect((shown?["result"] as? String)?.contains("Settings → Playback → Subtitles") == true)
        #expect(await c.perform(r.proposals[0], state: AppState(container: c)).isDone)
        #expect(s.subtitlesByDefault == true)
    }

    @Test func securitySettingsAreExplainedNeverOffered() async throws {
        let (c, _) = try rig()
        let web = ScriptedWeb([call("change_setting", #"{"id":"appLock","value":"off"}"#), say("That one you change in Settings → Privacy.")])
        let r = try await AssistantAgent.run(history: [(true, "turn off app lock")], context: nil, client: gemini(web), toolbox: AssistantToolbox(container: c))
        #expect(r.proposals.isEmpty)
        let result = ((((web.sent(1)["contents"] as? [[String: Any]])?.last?["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])?["response"] as? [String: Any])?["result"] as? String
        #expect(result?.contains("cannot be changed") == true)
    }

    @Test func aBadValueIsRefusedWithTheRealOptions() async throws {
        let (c, _) = try rig()
        let web = ScriptedWeb([call("change_setting", #"{"id":"theme","value":"Rainbow"}"#), say("Not one of the themes.")])
        let r = try await AssistantAgent.run(history: [(true, "rainbow theme")], context: nil, client: gemini(web), toolbox: AssistantToolbox(container: c))
        #expect(r.proposals.isEmpty)
        let result = ((((web.sent(1)["contents"] as? [[String: Any]])?.last?["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])?["response"] as? [String: Any])?["result"] as? String
        #expect(result?.contains("Cinematic") == true)
    }

    @Test func aTitleNotInTheLibraryIsNeverOffered() async throws {
        let (c, _) = try rig()
        let web = ScriptedWeb([call("play_title", #"{"title":"A Film That Does Not Exist"}"#), say("I could not find it.")])
        let r = try await AssistantAgent.run(history: [(true, "play it")], context: nil, client: gemini(web), toolbox: AssistantToolbox(container: c))
        #expect(r.proposals.isEmpty)
    }

    @Test func playbackControlNeedsSomethingPlaying() async throws {
        let (c, _) = try rig()
        let web = ScriptedWeb([call("control_playback", #"{"action":"pause"}"#), say("Nothing is playing.")])
        let r = try await AssistantAgent.run(history: [(true, "pause")], context: nil, client: gemini(web), toolbox: AssistantToolbox(container: c))
        #expect(r.proposals.isEmpty)
    }

    @Test func aModelThatWritesJSONInsteadOfWordsStillShowsWords() async throws {
        let (c, _) = try rig()
        let web = ScriptedWeb([say(#"{\"tool\":\"say\":\"Hello from a confused model.\"}"#)])
        let r = try await AssistantAgent.run(history: [(true, "hi")], context: nil, client: gemini(web), toolbox: AssistantToolbox(container: c))
        #expect(r.say == "Hello from a confused model.")
    }

    @Test func withNoAIQuestionsAboutSettingsAreStillAnswered() async throws {
        let (c, _) = try rig()
        let r = await AssistantToolbox(container: c).localReply("what does deinterlacing do?")
        #expect(r.say.lowercased().contains("interlaced"))
        let t = await AssistantToolbox(container: c).localReply("turn on subtitles by default")
        #expect(t.proposals.count == 1)
    }
}

@MainActor @Suite("Assistant: knowing the app") struct AssistantKnowledgeTests {
    @Test func everyChangeableSettingRoundTripsEveryOption() {
        IsolatedDefaults.with("kb") { d in
            for e in AppSettingsCatalog.all where e.changeable {
                let s = AppSettings(defaults: d)
                #expect(e.read != nil, "\(e.id) can be read")
                for o in e.options where !o.isEmpty { #expect(e.write?(s, o) == true, "\(e.id) accepts its own option “\(o)”"); #expect(e.read?(s).lowercased() == o.lowercased(), "\(e.id) reads back “\(o)”") }
            }
        }
    }
    @Test func noSettingIsDescribedTwiceAndAllHaveWords() {
        let ids = AppSettingsCatalog.all.map(\.id); #expect(Set(ids).count == ids.count)
        for e in AppSettingsCatalog.all { #expect(e.detail.count > 20, "\(e.id) has a real description"); #expect(e.path.hasPrefix("Settings") || e.path.hasPrefix("TV Guide"), "\(e.id) says where it is") }
    }
    @Test func securityAndAccountsAreExplainedButNotChangeable() {
        for id in ["appLock", "parental", "proxy", "vpn", "icloudSync", "lanSync", "maintenance", "tmdb", "integrations"] { #expect(AppSettingsCatalog.find(id)?.changeable == false, "\(id) must not be changeable") }
        let writable = AppSettingsCatalog.all.filter(\.changeable).map { $0.id.lowercased() }
        for banned in ["applock", "proxy", "icloud", "lansync", "vpn", "apikey", "token", "password", "parental", "pincode"] { #expect(!writable.contains { $0.contains(banned) }) }
    }
    @Test func questionsFindTheRightSetting() {
        #expect(AppSettingsCatalog.search("subtitles by default").first?.id == "subtitlesByDefault")
        #expect(AppSettingsCatalog.search("how do I stop it playing the next episode").first?.id == "autoPlayNextEpisode")
        #expect(AppSettingsCatalog.search("deinterlacing").first?.id == "deinterlace")
        #expect(AppSettingsCatalog.search("buffer").first?.id == "bufferingMode")
        #expect(AppSettingsCatalog.search("night mode loud").first?.id == "audioProcessing")
    }
    @Test func numbersAreClampedAndColoursAreChoices() {
        IsolatedDefaults.with("kb") { d in
            let s = AppSettings(defaults: d)
            #expect(AppSettingsCatalog.find("subtitleSize")?.write?(s, "500%") == true); #expect(s.subtitleSize == 200)
            #expect(AppSettingsCatalog.find("subtitleBackground")?.write?(s, "30") == true); #expect(abs(s.subtitleBackground - 0.3) < 0.001)
            #expect(AppSettingsCatalog.find("subtitleColor")?.write?(s, "Yellow") == true); #expect(s.subtitleColor == .yellow)
            #expect(AppSettingsCatalog.find("preferredSubtitleLanguage")?.write?(s, "Telugu") == true); #expect(s.preferredSubtitleLanguage == "te")
        }
    }
    @Test func howToArticlesAreFound() {
        #expect(AppGuide.search("it keeps buffering").first?.title == "Playback problems")
        #expect(AppGuide.search("how do i add to favourites").first?.title == "Favorites and Watch Later")
        #expect(AppGuide.search("record a channel").first?.title == "Recording and downloads")
    }
    @Test func theWordsOfTheContextCarryNoSecrets() {
        var c = AssistantContext(); c.screen = "Home: Discover"; c.nowPlaying = "Jersey"; c.library = "1 playlist(s), 10 channels"
        #expect(!c.text.lowercased().contains("password")); #expect(c.text.contains("Jersey"))
        #expect(AssistantAgent.system(context: nil, compact: false).contains("cannot see their screen"))
        #expect(AssistantAgent.system(context: c, compact: true).contains("Home: Discover"))
    }
}

@Suite("Assistant: diagnosing problems") struct AssistantDiagnosisTests {
    private func ev(_ f: (inout PlaybackEvidence) -> Void) -> PlaybackEvidence { var e = PlaybackEvidence(); e.playing = true; e.availableEngines = [.avPlayer, .mpv]; f(&e); return e }

    @Test func everyPlayerErrorBlamesTheRightParty() {
        let table: [(PlaybackError.Kind, AssistantFinding.Cause)] = [
            (.nameLookup, .network), (.network, .network), (.authorization, .credentials), (.unsupportedFormat, .format), (.timeout, .provider),
            (.providerBusy, .provider), (.providerUnavailable, .outage), (.notFound, .provider), (.engineUnavailable, .app), (.unknown, .unknown),
        ]
        for (kind, cause) in table {
            let f = AssistantDiagnostics.playback(ev { $0.playing = false; $0.failure = PlaybackError(kind); $0.failureIsRecent = true })
            #expect(f.cause == cause, "\(kind)"); #expect(!f.next.isEmpty, "\(kind) always gives a next step"); #expect(!f.why.isEmpty || kind == .unknown)
        }
    }
    @Test func aFormatErrorOffersTheOtherEngine() {
        let f = AssistantDiagnostics.playback(ev { $0.playing = false; $0.engine = .avPlayer; $0.failure = PlaybackError(.unsupportedFormat); $0.failureIsRecent = true })
        #expect(f.actions.contains("engine:mpv"))
        let only = AssistantDiagnostics.playback(ev { $0.playing = false; $0.availableEngines = [.avPlayer]; $0.failure = PlaybackError(.unsupportedFormat); $0.failureIsRecent = true })
        #expect(!only.actions.contains { $0.hasPrefix("engine:") }, "no engine to offer when there is only one")
    }
    @Test func bufferingWithASlowConnectionIsTheNetwork() {
        let f = AssistantDiagnostics.playback(ev { $0.stalls = 5; $0.observedMbps = 2; $0.streamMbps = 6 })
        #expect(f.cause == .network); #expect(f.text.contains("Large buffer"))
    }
    @Test func bufferingWithDroppedFramesIsTheDevice() { #expect(AssistantDiagnostics.playback(ev { $0.stalls = 4; $0.droppedFrames = 500 }).cause == .device) }
    @Test func bufferingWithoutADiagnosisPointsAtTheProviderAndOffersTheOtherEngine() {
        let f = AssistantDiagnostics.playback(ev { $0.stalls = 4; $0.observedMbps = 20; $0.streamMbps = 4; $0.engine = .mpv })
        #expect(f.cause == .provider); #expect(f.actions.contains("engine:avPlayer"))
    }
    @Test func aHealthyStreamIsSaidToBeHealthy() { #expect(AssistantDiagnostics.playback(ev { _ in }).cause == .fine) }
    @Test func nothingPlayingIsSaidSo() { #expect(AssistantDiagnostics.playback(PlaybackEvidence()).what.contains("Nothing is playing")) }
    @Test func offlineIsTheNetworkNotTheApp() { #expect(AssistantDiagnostics.playback(ev { $0.online = false }).cause == .network) }
    @Test func theAnswerHasTheFourPartsAndNoSecrets() {
        var e = ev { $0.playing = false; $0.failure = PlaybackError(.nameLookup, detail: "host.example"); $0.failureIsRecent = true }
        e.timeline = ["failed: nameLookup 10:00:01"]
        let t = AssistantDiagnostics.playback(e).text
        #expect(t.contains("What StreamSetu saw")); #expect(t.contains("Try this next"))
        #expect(!t.lowercased().contains("password")); #expect(!t.contains("http"))
    }
    @Test func guideFindings() {
        var g = AssistantDiagnostics.GuideEvidence(); g.source = "Mine"
        #expect(AssistantDiagnostics.guide(g).what.contains("no guide address"))
        g.hasGuideAddress = true
        #expect(AssistantDiagnostics.guide(g).actions.contains("sync_guide"))
        g.programmes = 5000; g.channels = 400; g.mapped = 20; g.lastUpdate = Date()
        #expect(AssistantDiagnostics.guide(g).cause == .provider)
        g.mapped = 380
        #expect(AssistantDiagnostics.guide(g).cause == .fine)
        g.lastUpdate = Date().addingTimeInterval(-5 * 86400)
        #expect(AssistantDiagnostics.guide(g).cause == .guide)
    }
    @Test func sourceHealthFindings() {
        var s = AssistantDiagnostics.SourceEvidence(); s.name = "Mine"; s.kind = "xtream"; s.channels = 10; s.lastSync = Date()
        #expect(AssistantDiagnostics.sourceHealth(s).cause == .fine)
        s.probe = .failed(.nameLookup); #expect(AssistantDiagnostics.sourceHealth(s).cause == .network)
        s.probe = .failed(.timeout); #expect(AssistantDiagnostics.sourceHealth(s).cause == .provider)
        s.probe = .reachable(401); #expect(AssistantDiagnostics.sourceHealth(s).cause == .credentials)
        s.probe = .reachable(200); s.syncStatus = "failed: server error"; #expect(AssistantDiagnostics.sourceHealth(s).actions.contains("refresh"))
        s.enabled = false; #expect(AssistantDiagnostics.sourceHealth(s).what.contains("switched off"))
    }
    @Test func theSyncStatusIsRedactedBeforeItIsShown() {
        var s = AssistantDiagnostics.SourceEvidence(); s.name = "Mine"; s.channels = 1; s.syncStatus = "failed: http://u:secretpw@host/get.php?username=u&password=secretpw"
        let t = AssistantDiagnostics.sourceHealth(s).text
        #expect(!t.contains("secretpw"))
    }
    @Test func engineAdviceMirrorsAutomatic() {
        #expect(AssistantDiagnostics.engineAdvice(container: .hls, current: .avPlayer, preference: .automatic, available: [.avPlayer, .mpv], hadFormatError: false).what.contains("AVPlayer"))
        let mkv = AssistantDiagnostics.engineAdvice(container: .mkv, current: .avPlayer, preference: .automatic, available: [.avPlayer, .mpv], hadFormatError: false)
        #expect(mkv.what.contains("MPV")); #expect(mkv.actions.contains("engine:mpv"))
    }
}

@Suite("Assistant: understanding what was asked") struct AssistantRouterTests {
    @Test func theRoutesFromTheSpec() {
        let table: [(String, AssistantIntent)] = [
            ("why is this channel buffering?", .diagnosePlayback), ("this channel is not playing", .diagnosePlayback), ("black screen on this stream", .diagnosePlayback),
            ("why is the guide empty?", .diagnoseGuide), ("epg is wrong by hours", .diagnoseGuide),
            ("is my playlist working?", .sourceHealth), ("check my provider server", .sourceHealth),
            ("which engine should I use, avplayer or mpv", .engineAdvice),
            ("how do I add an xtream source", .addSource), ("how do i add my playlist?", .addSource), ("add a jellyfin server", .addSource),
            ("where is my data stored?", .privacy), ("do you collect anything", .privacy),
            ("where can I get free iptv", .unsupported), ("give me a playlist with all channels", .unsupported),
            ("play the next episode", .playbackControl), ("resume", .playbackControl),
            ("turn on subtitles by default", .explainSettings), ("what does deinterlacing do", .explainSettings),
            ("bigg boss", .general), ("something funny tonight", .general),
        ]
        for (text, want) in table { #expect(AssistantRouter.route(text) == want, "“\(text)”") }
    }
    @Test func sourceKindsAreRecognised() {
        #expect(AssistantRouter.sourceKind(in: "add my Xtream login") == "Xtream"); #expect(AssistantRouter.sourceKind(in: "plex token") == "Plex")
        #expect(AssistantRouter.sourceKind(in: "an m3u link") == "M3U link"); #expect(AssistantRouter.sourceKind(in: "hello") == nil)
    }
}

@MainActor @Suite("Assistant: tools and fallback") struct AssistantToolsTests {
    private func rig() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-at-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    @Test func searchEverythingFindsChannelsSeriesAndRunTogetherSpelling() async throws {
        let c = try rig()
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "c1", "BIGG BOSS 24X7 TELUGU"), TestSupport.channel(src, "c2", "Sun News")])
        try c.indexer.commitSeries(source: src, categories: [], series: [TestSupport.series(src, "s1", "Bigg Boss Telugu")])
        for q in ["bigg boss", "biggboss", "BiggBoss"] {
            let out = await AssistantToolbox(container: c).run("search_everything", ["query": .string(q)])
            #expect(out.contains("Live TV"), "“\(q)” finds the live channel"); #expect(out.contains("Series"), "“\(q)” finds the series"); #expect(!out.contains("Sun News"))
        }
        let none = await AssistantToolbox(container: c).run("search_everything", ["query": .string("zzzqqq")])
        #expect(none.hasPrefix("Nothing named"))
    }

    @Test func theChannelFoundCanBeOffered() async throws {
        let c = try rig()
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "c1", "Star Maa HD")])
        let t = AssistantToolbox(container: c)
        _ = await t.run("search_everything", ["query": .string("star maa")])
        #expect(t.proposals.count == 1)
    }

    @Test func noAIStillAnswersAProblemFromEvidence() async throws {
        let c = try rig()
        let r = await AssistantToolbox(container: c).localReply("why is this channel buffering?")
        #expect(r.say.contains("Nothing is playing"))
        let g = await AssistantToolbox(container: c).localReply("why is the guide empty?")
        #expect(!g.say.isEmpty)
        let refuse = await AssistantToolbox(container: c).localReply("where can I get free iptv")
        #expect(refuse.say.contains("does not provide channels"))
        let add = await AssistantToolbox(container: c).localReply("how do I add an xtream source")
        #expect(add.say.contains("Username") || add.say.contains("Server"))
    }

    @Test func setupHelpNeverAsksForSecretsToBeTypedHere() async throws {
        let c = try rig()
        let t = await AssistantToolbox(container: c).run("source_setup_help", ["type": .string("Plex")])
        #expect(t.contains("X-Plex-Token")); #expect(t.contains("Keychain"))
    }

    @Test func sourceHealthNeverReturnsAnAddress() async throws {
        let c = try rig()
        _ = try c.sources.addM3U(name: "Mine", url: "http://user:pass@127.0.0.1:9/list.m3u?token=abc")
        let out = await AssistantToolbox(container: c).run("source_health", ["source": .string("Mine")])
        #expect(!out.contains("pass")); #expect(!out.contains("token=")); #expect(!out.contains("http://"))
    }

    @Test func onlineModelsAreLeftOutWhenThePersonSaysSo() throws {
        let c = try rig()
        c.ai.save(AIConfig(provider: .gemini, model: "", base: "", key: "K")); c.ai.save(AIConfig(provider: .groq, model: "", base: "", key: "K2"))
        c.ai.provider = .gemini
        c.assistantCloudAllowed = true
        #expect(c.assistantModelChain().first?.provider == .gemini); #expect(c.assistantModelChain().contains { $0.provider == .groq })
        c.assistantCloudAllowed = false
        #expect(!c.assistantModelChain().contains { $0.provider == .gemini || $0.provider == .groq })
    }

    @Test func aBlipIsRetriedButAKeyProblemIsNot() {
        #expect(AppContainer.isTransient(.rejected("Google Gemini does not know the model \"x\". Change the model name in Settings.")))
        #expect(AppContainer.isTransient(.network("Google Gemini is not answering (503).")))
        #expect(!AppContainer.isTransient(.rejected("Google Gemini did not accept the key.")))
    }

    @Test func replyTextShowsBoldWithoutAsterisks() {
        let a = AssistantText.attributed("Yes, **Khaleja (2010)** is in your library.")
        #expect(!String(a.characters).contains("*")); #expect(String(a.characters).contains("Khaleja (2010)"))
    }
}

@MainActor @Suite("Assistant: fixes from real use") struct AssistantRealUseTests {
    private func rig() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-ru-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    @Test func screenAndStatsQuestionsAreRouted() {
        for t in ["what is on my screen?", "what am i looking at", "where am i"] { #expect(AssistantRouter.route(t) == .screen, "“\(t)”") }
        for t in ["How much did I watch this week?", "what is my watch time", "what did i watch the most"] { #expect(AssistantRouter.route(t) == .stats, "“\(t)”") }
    }

    @Test func theScreenIsAnsweredByTheAppFromTheContext() throws {
        let t = AssistantToolbox(container: try rig())
        t.context = nil
        #expect(t.screenAnswer().contains("Screen sharing is off"))
        var c = AssistantContext(); c.screen = "Home: Discover"; c.searchText = "bigg boss"; c.nowPlaying = "Jersey"; c.library = "1 playlist(s), 10 channels"
        t.context = c
        let a = t.screenAnswer()
        #expect(a.contains("Home: Discover")); #expect(a.contains("bigg boss")); #expect(a.contains("Jersey"))
    }

    @Test func aBareNameIsSearchedEverywhereBeforeAnyModelIsAsked() async throws {
        let c = try rig()
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "c1", "BIGG BOSS 24X7 TELUGU")])
        try c.indexer.commitSeries(source: src, categories: [], series: [TestSupport.series(src, "s1", "Bigg Boss Telugu")])
        let ev = await AssistantToolbox(container: c).preload(.general, text: "bigg boss")
        #expect(ev?.contains("Live TV") == true); #expect(ev?.contains("Series") == true)
        let notAName = await AssistantToolbox(container: c).preload(.general, text: "who is nani")
        #expect(notAName == nil, "a question is not looked up as a title")
    }

    @Test func viewingNumbersAreGatheredBeforeTheModelAnswers() async throws {
        let ev = await AssistantToolbox(container: try rig()).preload(.stats, text: "how much did I watch this week")
        #expect(ev?.hasPrefix("Viewing numbers:") == true)
    }

    @Test func postersAreOnlyForWhatTheReplyIsAbout() throws {
        let src = PlaylistSource(name: "x", type: .m3uRemote, baseURL: "http://h")
        var pokiri = TestSupport.movie(src, "m1", "Pokiri (2006)"); pokiri.title = "Pokiri (2006)"
        let noise = TestSupport.movie(src, "m2", "Bigg Boss OTT")
        var a = AskAnswer(intent: WatchIntent(keywords: ["mahesh", "babu"]))
        a.results = [AskResult(item: .movie(noise), reasons: ["Matches your words"], score: 1, watched: false), AskResult(item: .movie(pokiri), reasons: ["Matches your words"], score: 1, watched: false)]
        let kept = AssistantAgent.cardsMatching("Yes, Pokiri is in your library.", a)
        #expect(kept?.results.map(\.item.title) == ["Pokiri (2006)"])
        let none = AssistantAgent.cardsMatching("I could not find that.", a)
        #expect(none?.results.isEmpty == true, "loose matches are not shown as if they were the answer")
        a.results.append(AskResult(item: .movie(pokiri), reasons: ["Suggested by the assistant"], score: 1, watched: false))
        #expect(AssistantAgent.cardsMatching("Here you go.", a)?.results.count == 1, "titles the assistant suggested and checked are kept")
    }
}

@Suite("Assistant: spelling without spaces") struct AssistantSpellingTests {
    @Test func splitsAreGuessedForAnyWordInThePhrase() {
        #expect(AssistantToolbox.searchVariants("biggboss telugu").contains("bigg boss telugu"))
        #expect(AssistantToolbox.searchVariants("biggboss").contains("bigg boss"))
        #expect(AssistantToolbox.searchVariants("bigg boss telugu").contains("biggbosstelugu"))
        #expect(AssistantToolbox.searchVariants("Nani").count == 1, "short words are left alone")
        #expect(AssistantToolbox.searchVariants("biggboss telugu").first == "biggboss telugu", "what was typed is tried first")
    }
}

@MainActor @Suite("Assistant: spelling against a library") struct AssistantSpellingLibraryTests {
    @Test func biggbossTeluguFindsTheChannelAndTheSeries() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-sp-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "c1", "BIGG BOSS 24X7 TELUGU"), TestSupport.channel(src, "c2", "BIGG BOSS 24X7 HINDI")])
        try c.indexer.commitSeries(source: src, categories: [], series: [TestSupport.series(src, "s1", "Bigg Boss (Telugu)"), TestSupport.series(src, "s2", "Bigg Boss Kannada")])
        let out = await AssistantToolbox(container: c).run("search_everything", ["query": .string("biggboss telugu")])
        #expect(out.contains("BIGG BOSS 24X7 TELUGU")); #expect(out.contains("Bigg Boss (Telugu)"))
        #expect(!out.contains("HINDI") && !out.contains("Kannada"), "a guessed spelling keeps only titles with every word")
    }
}

@MainActor @Suite("Assistant: the settings that were missing") struct AssistantNewSettingsTests {
    @Test func guideSettingsTakeOnlyWhatTheScreensOffer() { IsolatedDefaults.with("ns") { d in
        let s = AppSettings(defaults: d)
        #expect(AppSettingsCatalog.find("guideRetentionDays")?.write?(s, "7 days") == true); #expect(s.guideRetentionDays == 7)
        #expect(AppSettingsCatalog.find("guideRetentionDays")?.write?(s, "3 hours") == true); #expect(s.guideRetentionDays == 0)
        #expect(AppSettingsCatalog.find("guideRetentionDays")?.write?(s, "10 days") == false, "not one of the picker's choices")
        #expect(AppSettingsCatalog.find("guideHoursVisible")?.write?(s, "6 hours") == true); #expect(s.guideHoursVisible == 6)
        #expect(AppSettingsCatalog.find("guideHoursVisible")?.write?(s, "5 hours") == false, "the grid shows 2, 3, 4 or 6")
    } }
    @Test func subtitlePositionIsBoundedAndSaysItNeedsMPV() { IsolatedDefaults.with("ns") { d in
        let s = AppSettings(defaults: d); let e = AppSettingsCatalog.find("subtitlePosition")
        #expect(e?.write?(s, "80%") == true); #expect(abs(s.subtitlePosition - 0.8) < 0.001)
        #expect(e?.write?(s, "400") == true); #expect(s.subtitlePosition == 1, "clamped to the top")
        #expect(e?.detail.contains("MPV") == true)
    } }
}

@MainActor @Suite("Assistant: answering a name at once") struct AssistantFastNameTests {
    private func rig() throws -> (AppContainer, PlaylistSource) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-fn-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        var a = TestSupport.channel(src, "c1", "BIGG BOSS TELUGU 24X7", cat: nil); a.streamRef = "http://127.0.0.1:9/live/1.ts"
        var b = TestSupport.channel(src, "c2", "BIGG BOSS 24X7 TELUGU", cat: nil); b.streamRef = "http://127.0.0.1:9/live/2.ts"
        try c.indexer.commitChannels(source: src, categories: [], channels: [a, b])
        try c.indexer.commitSeries(source: src, categories: [], series: [TestSupport.series(src, "s1", "Bigg Boss (Telugu)"), TestSupport.series(src, "s2", "Bigg Boss Telugu")])
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "m1", "Star", year: 2024)])
        return (c, src)
    }

    @Test func aBareNameIsAnsweredFromTheAppsOwnSearchWithNoModel() async throws {
        let (c, _) = try rig()
        let r = try #require(await AssistantToolbox(container: c).fastNameReply("biggboss telugu"))
        #expect(r.say.contains("2 live channels")); #expect(r.say.contains("2 series"))
        #expect(r.answer?.results.count == 2, "posters are the series found by name")
        #expect(!(r.answer?.results.contains { $0.item.title == "Star" } ?? false), "a loose match is not shown")
        #expect(r.proposals.count == 1, "one play button for the best channel, not two")
        #expect(r.answer?.intent.summary.isEmpty == true, "no keyword chips")
    }

    @Test func questionsPeopleAndMissesAreLeftToTheModel() async throws {
        let (c, _) = try rig()
        for text in ["who is nani", "why is this buffering", "turn on subtitles", "zzzqqq", "something funny tonight"] {
            #expect(await AssistantToolbox(container: c).fastNameReply(text) == nil, "“\(text)”")
        }
    }

    @Test func theSameOfferIsNotMadeTwice() async throws {
        let (c, _) = try rig()
        let t = AssistantToolbox(container: c)
        _ = await t.run("search_everything", ["query": .string("bigg boss telugu")])
        _ = await t.run("search_everything", ["query": .string("biggboss telugu")])
        #expect(t.proposals.count == 1)
    }

    @Test func theInstantAnswerCanBeHandedToTheAI() async throws {
        let (c, _) = try rig()
        let look: @MainActor () -> (screen: String, item: LibraryItem?, search: String?) = { ("Home", nil, nil) }
        // the instant answer is marked, and carries the words so the button can send them on
        let quick = try #require(await AssistantToolbox(container: c).fastNameReply("bigg boss telugu"))
        #expect(quick.instant)
        let first = try await c.askAssistant(history: [(true, "bigg boss telugu")], context: nil, onStep: { _ in })
        #expect(first.instant, "answered at once")
        let again = try await c.askAssistant(history: [(true, "bigg boss telugu")], context: nil, onStep: { _ in }, skipInstant: true)
        #expect(!again.instant, "skipInstant goes past the quick search")
        // through the chat model: the button's label is shown, and the words are what is asked
        let model = AssistantModel()
        /// Waits until the chat has finished answering the latest person message: not busy, and an assistant message after it.
        func settled() async {
            for _ in 0..<1500 {
                if !model.busy, let i = model.messages.lastIndex(where: { $0.role == .person }), model.messages.suffix(from: i).contains(where: { $0.role == .assistant }) { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        model.send("bigg boss telugu", container: c, look: look)
        await settled()
        #expect(model.messages.last?.askAIText == "bigg boss telugu", "the instant answer offers the button")
        model.send("bigg boss telugu", container: c, look: look, viaAI: true)
        await settled()
        #expect(model.messages.contains { $0.role == .person && $0.text == "Ask AI about “bigg boss telugu”" })
        #expect(model.messages.last?.role == .assistant && model.messages.last?.askAIText == nil, "the second answer does not offer the button again")
    }

    @Test func playCommandsOnlyBecomeButtonsForRealTitles() throws {
        let (c, _) = try rig()
        #expect(c.assistantCommandProposals("play somwthing") == nil, "a misspelt word is not a title")
        #expect(c.assistantCommandProposals("play something") == nil)
        #expect(c.assistantCommandProposals("play something best series") == nil, "a request, not a title")
        let play = try #require(c.assistantCommandProposals("play Star"))
        guard case .playItem(_, let isChannel, let title) = play[0].kind else { Issue.record("expected an exact play offer"); return }
        #expect(title == "Star" && !isChannel)
        let channel = try #require(c.assistantCommandProposals("play BIGG BOSS TELUGU 24X7"))
        if case .playItem(_, let isChannel, _) = channel[0].kind { #expect(isChannel) } else { Issue.record("expected a channel offer") }
        let later = try #require(c.assistantCommandProposals("add Star to watch later"))
        if case .toggleList(_, _, let watchLater, let on, _) = later[0].kind { #expect(watchLater && on) } else { Issue.record("expected a list offer") }
        #expect(c.assistantCommandProposals("add Nothing Like This to favourites") == nil)
        #expect(c.assistantCommandProposals("go to live tv")?.count == 1, "screens need no title")
        #expect(c.assistantCommandProposals("resume")?.count == 1)
        #expect(c.assistantCommandProposals("what should I watch tonight") == nil)
    }

    @Test func noAIAlsoTreatsAnUnmatchedPlayAsARequest() async throws {
        let (c, _) = try rig()
        let r = await AssistantToolbox(container: c).localReply("play something best series")
        // real series are shown, and the only Play button is for one of them: none is made for the phrase itself
        #expect(!(r.answer?.results.isEmpty ?? true))
        for p in r.proposals { if case .playItem(let id, _, _) = p.kind { #expect(r.answer?.results.contains { $0.item.id == id } == true) } else { Issue.record("only a real title may be offered") } }
    }

    @Test func theHintReachesTheModel() {
        let sys = AssistantAgent.system(context: nil, compact: false, evidence: "The person says the quick search results for this name were not what they meant.")
        #expect(sys.contains("not what they meant"))
    }

    @Test func aTitleIsOnlyMentionedAsAWholeWord() throws {
        let src = PlaylistSource(name: "x", type: .m3uRemote, baseURL: "http://h")
        var a = AskAnswer(intent: WatchIntent())
        a.results = [AskResult(item: .movie(TestSupport.movie(src, "m1", "Star", year: 2024)), reasons: ["Matches your words"], score: 1, watched: false)]
        #expect(AssistantAgent.cardsMatching("I've put a button below so you can start watching right away.", a)?.results.isEmpty == true, "“star” inside “start” is not a mention")
        #expect(AssistantAgent.cardsMatching("Star is in your library.", a)?.results.count == 1)
    }
}

@MainActor @Suite("Assistant: descriptions become titles, titles become library matches") struct AssistantTitleBridgeTests {
    private func rig() throws -> AppContainer {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-tb-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        try c.indexer.commitMovies(source: src, categories: [], movies: [TestSupport.movie(src, "m1", "Drishyam (2013) (Malayalam)", year: 2013), TestSupport.movie(src, "m2", "Pokiri (2006)", year: 2006), TestSupport.movie(src, "m3", "Athadu (2005) (Telugu)", year: 2005), TestSupport.movie(src, "m4", "Oldboy (2013)", year: 2013)])
        return c
    }

    @Test func descriptiveRequestsAreNotLookedUpAsNames() async throws {
        let c = try rig()
        for text in ["best horror movies", "best seat edge thrillers", "top 10 netflix movies this week", "marvel all four phases", "netflix top movies in india", "best learning documentaries", "films like athadu", "award winning telugu movies"] {
            #expect(await AssistantToolbox(container: c).fastNameReply(text) == nil, "“\(text)” describes titles; it is not a name")
            #expect(await AssistantToolbox(container: c).preload(.general, text: text) == nil, "“\(text)” is left to the AI to turn into titles")
        }
        #expect(await AssistantToolbox(container: c).fastNameReply("Pokiri") != nil, "a plain name is still answered at once")
    }

    @Test func theAIsTitlesAreMatchedOneByOneInItsOrderWithTheRestListedApart() async throws {
        let c = try rig(); let t = AssistantToolbox(container: c)
        let out = await t.run("check_library", ["titles": .strings(["Athadu (2005)", "Drishyam (2013) / Drushyam", "Inception (2010)", "Pokiri (2006)", "Parasite (2019)"])])
        #expect(out.contains("In the library")); #expect(out.contains("Not in the library: Inception (2010); Parasite (2019)"))
        let shown = (t.lastAnswer?.results ?? []).map(\.item.title)
        #expect(shown == ["Athadu (2005) (Telugu)", "Drishyam (2013) (Malayalam)", "Pokiri (2006)"], "the AI's order is kept: \(shown)")
        #expect(t.lastAnswer?.elsewhere == ["Inception (2010)", "Parasite (2019)"])
    }

    @Test func aMatchThatDisagreesOnTheYearIsFlaggedNotSilentlyAccepted() async throws {
        let c = try rig(); let t = AssistantToolbox(container: c)
        let out = await t.run("check_library", ["titles": .strings(["Oldboy (2003)", "Pokiri (2006)"])])
        #expect(out.contains("Possible matches")); #expect(out.contains("Oldboy"))
        #expect(t.lastAnswer?.results.first { $0.item.title.hasPrefix("Oldboy") }?.reasons == ["Possible match"])
        #expect(t.lastAnswer?.results.first { $0.item.title.hasPrefix("Pokiri") }?.reasons == ["Suggested by the assistant"])
        // firm matches come before possible ones
        #expect(t.lastAnswer?.results.map(\.item.title) == ["Pokiri (2006)", "Oldboy (2013)"])
    }

    @Test func nothingFoundSaysSoAndShowsNoCards() async throws {
        let c = try rig(); let t = AssistantToolbox(container: c)
        let out = await t.run("check_library", ["titles": .strings(["Nothing Like This (2001)", "Neither Is This (1999)"])])
        #expect(out.contains("None of those titles are in the library")); #expect(t.lastAnswer?.results.isEmpty == true); #expect(t.lastAnswer?.elsewhere.count == 2)
    }

    @Test func theToolIsDescribedAsTheBridgeAndTheModelIsToldToUseIt() throws {
        let c = try rig()
        let spec = try #require(AssistantToolbox(container: c).specs(compact: false).first { $0.name == "check_library" })
        #expect(spec.help.contains("order you recommend")); #expect(spec.help.contains("alternate spellings"))
        let sys = AssistantAgent.system(context: nil, compact: false)
        #expect(sys.contains("Do NOT search for those words")); #expect(sys.contains("call check_library ONCE"))
    }

    @Test func aScriptedConversationShowsOnlyRealCardsAndListsTheMissing() async throws {
        let c = try rig()
        let call = #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"check_library","args":{"titles":["Athadu (2005)","Inception (2010)","Pokiri (2006)"]}}}]}}]}"#
        let say = #"{"candidates":[{"content":{"parts":[{"text":"You have Athadu and Pokiri. Inception is not in your library."}]}}]}"#
        let web = ScriptedWeb([call, say])
        var client = AIClient(config: AIConfig(provider: .gemini, model: "", base: "", key: "K")); client.transport = web.transport
        let r = try await AssistantAgent.run(history: [(true, "best thrillers")], context: nil, client: client, toolbox: AssistantToolbox(container: c))
        #expect(r.answer?.results.map(\.item.title) == ["Athadu (2005) (Telugu)", "Pokiri (2006)"]); #expect(r.answer?.elsewhere == ["Inception (2010)"])
    }
}

@MainActor @Suite("Assistant: follow-up chips and screen filters") struct AssistantChipTests {
    private func rig() throws -> (AppContainer, [AskResult]) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-ch-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Mine", url: "http://127.0.0.1:9/list.m3u")
        var long = TestSupport.movie(src, "a", "Long Old", year: 2001); long.durationSeconds = 9000
        var short = TestSupport.movie(src, "b", "Short Mid", year: 2012); short.durationSeconds = 5400
        var new = TestSupport.movie(src, "c", "Brand New", year: 2025); new.durationSeconds = 7200
        try c.indexer.commitMovies(source: src, categories: [], movies: [long, short, new])
        let all = [long, short, new].map { m in AskResult(item: .movie(try! c.catalog.movie(id: m.id)!), reasons: [], score: 1, watched: false) }
        return (c, all)
    }

    @Test func newerOrdersTheShownTitlesAndIsNeverSearchedAsATitle() throws {
        let (c, shown) = try rig()
        let r = AssistantRefinement.apply(.newer, to: shown, container: c)
        #expect(r.results.map(\.item.title) == ["Brand New", "Short Mid", "Long Old"]); #expect(r.say == "Newest first.")
        let m = AssistantModel()
        m.messages = [.init(role: .assistant, text: "Here.", results: shown)]
        m.send("Newer ones", container: c, look: { ("Home", nil, nil) })
        #expect(m.messages.last?.text == "Newest first."); #expect(m.messages.last?.results.map(\.item.title) == ["Brand New", "Short Mid", "Long Old"])
        #expect(!m.busy, "answered at once, with no search for the words")
    }

    @Test func shorterPutsTheShortestFirstAndAdmitsWhenItCannotTell() throws {
        let (c, shown) = try rig()
        #expect(AssistantRefinement.apply(.shorter, to: shown, container: c).results.first?.item.title == "Short Mid")
        let untimed = shown.map { x -> AskResult in x }.filter { _ in false }
        #expect(AssistantRefinement.apply(.shorter, to: untimed, container: c).say.contains("running times"))
    }

    @Test func unwatchedDropsWhatWasPlayed() throws {
        let (c, shown) = try rig()
        #expect(AssistantRefinement.apply(.unwatched, to: shown, container: c).say == "None of those has been watched yet.")
        var marked = shown; marked[0].watched = true
        #expect(AssistantRefinement.apply(.unwatched, to: marked, container: c).results.count == 2)
        #expect(AssistantRefinement.apply(.surprise, to: shown, container: c).results.count == 1)
    }

    @Test func aScreenCommandOnlyCarriesWordsTheLibraryUnderstands() {
        let k = SearchCommands.parse("new movies today in telugu 2026 folder")
        guard case .go(let target, let filter)? = k.first?.kind else { Issue.record("expected a screen command"); return }
        #expect(target == .movies); #expect(filter?.contains("today") == false); #expect(filter?.contains("folder") == false)
        #expect(filter?.contains("telugu") == true); #expect(filter?.contains("2026") == true)
        guard case .go(_, let plain)? = SearchCommands.parse("show me movies").first?.kind else { Issue.record("expected a screen command"); return }
        #expect(plain == nil, "no filter words at all: the screen opens with its own list")
    }
}
