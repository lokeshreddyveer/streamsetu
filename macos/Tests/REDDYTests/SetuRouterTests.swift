import Foundation
import Testing
@testable import REDDY

/// What a typed question is about. Questions about the app (what a setting is, where something is, why a feature failed, in English, Hinglish or Telugu in Latin letters) must reach Setu's knowledge before any
/// playback, media-search or live-tool intent; questions about what is playing right now keep the live tools; and a name or a play request is never taken for a question.
@Suite("Setu router: app help or media request") struct SetuRouterTests {
    static let appHelp: [String] = [
        "how do i turn on subtitles",
        "how do I add a favourite channel",
        "which screen has my favourites",
        "how do i refresh a playlist",
        "how do i check my playlist",
        "backup failed",
        "iCloud sync not working",
        "app lock not working",
        "download failed",
        "recording failed",
        "login error 401",
        "my reminders are not working",
        "how do i see my viewing history",
        "why is my icloud not syncing",
        "error while restoring a backup",
        "why does the app ask for my password again",
        "how to clear the queue in music",
        "where is the sleep timer",
        "what does crossfade do",
        "how do i fix buffering",
        "why won't my downloads finish",
        "how do i change the language",
        "how can i make subtitles bigger",
        "where can i find my favourites",
        "can i record on my iphone",
        "does it support mkv",
        "why are my notifications not showing",
        "how do I turn off setu seeing my screen",
        "what is smart mix",
        "why can't I see lyrics",
        "how do i change country for charts",
        "how do I set a sleep timer for music",
        "where do i find the equalizer",
        "my profile pin is not working",
        "the proxy setting failed",
        "trakt login failed",
        "why is the lock screen asking for touch id",
        "how to hide a folder with a pin",
        "how do i make a kids profile",
        "how do i limit how long my kid watches",
        "subtitles kaise on kare",
        "queue clear kaise",
        "song play ela",
        "lyrics kaise dekhe",
        "sound nahi aa raha",
        "guide khali kyun hai",
        "playlist refresh kaise kare",
        "volume kaise badhaye",
        "equalizer kahan hai",
        "sleep timer ela pettali",
        "devices nahi mil rahe",
        "lyrics ekkada undi",
        "subtitle ela on cheyali",
        "backup kaise le",
        "download kaise kare",
        "theme kaise badle",
        "crossfade ela on cheyali",
        "favourite kaise add kare",
        "lyrics kyun nahi aa rahe",
        "queue ekkada undi"
    ]

    /// Phrase to the route it must take. Live checks (what is playing, the guide, a playlist probe), the existing special routes and plain media requests.
    static let others: [(String, AssistantIntent)] = [
        ("play the next episode", .playbackControl),
        ("resume", .playbackControl),
        ("play inception", .playbackControl),
        ("bigg boss", .general),
        ("something funny tonight", .general),
        ("inception", .general),
        ("telugu movies 2024", .general),
        ("kgf", .general),
        ("arijit singh songs", .general),
        ("best comedy movies", .general),
        ("new telugu releases", .general),
        ("movies like inception", .general),
        ("what is inception about", .general),
        ("can i watch rrr", .general),
        ("who directed rrr", .general),
        ("why is this channel buffering?", .diagnosePlayback),
        ("this channel is not playing", .diagnosePlayback),
        ("black screen on this stream", .diagnosePlayback),
        ("why is the guide empty?", .diagnoseGuide),
        ("epg is wrong by hours", .diagnoseGuide),
        ("is my playlist working?", .sourceHealth),
        ("check my provider server", .sourceHealth),
        ("which engine should I use, avplayer or mpv", .engineAdvice),
        ("how do i add an xtream source", .addSource),
        ("add a jellyfin server", .addSource),
        ("where is my data stored?", .privacy),
        ("do you collect anything", .privacy),
        ("where can I get free iptv", .unsupported),
        ("how do i get free iptv", .unsupported),
        ("what is on my screen?", .screen),
        ("where am i", .screen),
        ("How much did I watch this week?", .stats),
        ("what did i watch the most", .stats),
        ("why is this stream so slow", .diagnosePlayback)
    ]

    @Test func appQuestionsRouteToKnowledgeAnswers() {
        #expect(Self.appHelp.count >= 55)
        for q in Self.appHelp { #expect(AssistantRouter.route(q) == .explainSettings, "\(q) -> \(AssistantRouter.route(q))") }
    }

    @Test func liveChecksSpecialRoutesAndMediaRequestsKeepTheirRoutes() {
        #expect(Self.others.count >= 30)
        for (q, want) in Self.others { #expect(AssistantRouter.route(q) == want, "\(q) -> \(AssistantRouter.route(q))") }
    }

    @Test func atLeastSixtyPhrasingsAreCovered() { #expect(Self.appHelp.count + Self.others.count >= 60) }

    @Test func aQuestionAboutTheAppIsNeverReadAsAMediaRequestOrANameSearch() {
        for q in Self.appHelp { #expect(AssistantRouter.isAppHelp(q), "\(q)") }
        for (q, want) in Self.others where want == .general || want == .playbackControl { #expect(!AssistantRouter.isAppHelp(q), "\(q)") }
    }

    @Test func errorFailedAndNotWorkingAboutAFeatureAreNotPlaybackDiagnoses() {
        for q in ["backup failed", "download failed", "recording failed", "login error 401", "iCloud sync not working", "app lock not working", "my reminders are not working"] {
            #expect(AssistantRouter.route(q) != .diagnosePlayback, "\(q)")
        }
        // ... while the same words about what is playing stay with the player's own numbers.
        for q in ["error on this channel", "this stream failed", "video not working right now"] { #expect(AssistantRouter.route(q) == .diagnosePlayback, "\(q)") }
    }

    @Test func aHowToAboutAFeatureWordIsNotALiveCheck() {
        #expect(AssistantRouter.route("how do I refresh a playlist") == .explainSettings)
        #expect(AssistantRouter.route("how do I check my playlist") == .explainSettings)
        #expect(AssistantRouter.route("is my playlist working?") == .sourceHealth)
        #expect(AssistantRouter.route("which screen has my favourites") == .explainSettings)
        #expect(AssistantRouter.route("what screen am i on") == .screen)
    }

    @Test func wordsAreMatchedWholeSoFirecrackerIsNotCrack() {
        #expect(AssistantRouter.route("how do i fix the firecracker animation") != .unsupported)
        #expect(AssistantRouter.route("where can I get pirate iptv") == .unsupported)
    }

    // MARK: Hinglish and Telugu cues

    @Test func hinglishAndTeluguQuestionWordsGiveTheRightIntent() {
        let cases: [(String, AtlasIntent)] = [
            ("subtitles kaise on kare", .howDoI), ("queue ela clear cheyali", .howDoI), ("song play ela", .howDoI), ("lyrics kaise dekhe", .howDoI),
            ("lyrics kahan hai", .whereIs), ("queue ekkada undi", .whereIs), ("guide khali kyun hai", .whyBroken), ("sound nahi aa raha", .whyBroken), ("audio ledu enduku", .whyBroken),
        ]
        for (q, want) in cases { #expect(IntentDetector.detect(q).intent == want, "\(q) -> \(IntentDetector.detect(q).intent)") }
    }

    // MARK: never a dead end

    @Test func theFallbackNamesWhatIsNearbyAndOffersToOpenIt() {
        let a = AtlasEntry.make("screen.x", .screen, "Playback settings", "The playback options of the app.", path: ["Settings", "Playback"], reach: .settingsPage("Playback"))
        let b = AtlasEntry.make("setting.y", .setting, "Subtitle size", "How large subtitles are.", path: ["Settings", "Playback", "Subtitles"])
        let r = Compose.fallback([a, b], intent: .other)
        #expect(r.text.contains("closest") && r.text.contains("Playback settings") && r.text.contains("Subtitle size"))
        #expect(r.actions.contains { $0.kind == .openThis && $0.entryID == "screen.x" })
        #expect(r.actions.filter { $0.kind == .pick }.count == 2)
        #expect(!r.text.contains("I am not sure what you mean"))
    }

    @Test func theFallbackWithNothingNearbyStillSaysWhatSetuCanDo() {
        let r = Compose.fallback([], intent: .other)
        #expect(r.text.contains(Compose.capabilities) && !r.text.isEmpty)
        #expect(r.text.lowercased().contains("rather say so"))
    }

    @MainActor @Test func aWeakQuestionStillGetsNearbyTopicsFromTheRealAtlas() {
        let hits = Atlas.engine.retrieve("how do i make the app greener", platform: .mac, limit: 6).hits.map(\.entry)
        let r = Compose.fallback(Array(hits.prefix(3)), intent: .howDoI)
        #expect(!r.text.isEmpty)
        #expect(hits.isEmpty || r.actions.contains { $0.kind == .pick })
    }
}
