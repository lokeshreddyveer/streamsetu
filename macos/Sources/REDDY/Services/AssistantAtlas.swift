import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What Setu says for a question, with the buttons it offers. Every button is an ordinary assistant proposal, so the authorizer checks it again when it is tapped.
struct AtlasReply {
    var text: String
    var proposals: [AssistantProposal]
    /// Other topics the person can pick; each is sent back as a message.
    var chips: [String]
    /// The Atlas entry each chip stands for, same order as `chips`: a chip is opened by id, never re-asked as free text.
    var chipIDs: [String] = []
    var decision: AtlasDecision
    var entryIDs: [String]
    /// Entries Show-me can point at: each becomes a "Show me" button under the answer.
    var showMe: [String] = []
}

/// The bridge between the answer engine and the assistant. Deterministic and offline: it needs no language model, no key and no network.
@MainActor enum AtlasAssistant {
    static var platform: AtlasPlatforms {
        #if os(macOS)
        .mac
        #elseif canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #else
        .mac
        #endif
    }
    static var appStore: Bool {
        #if STREAMSETU_APPSTORE
        true
        #else
        false
        #endif
    }

    static func visible(_ e: AtlasEntry, platform p: AtlasPlatforms = AtlasAssistant.platform, appStore store: Bool = AtlasAssistant.appStore) -> Bool {
        !e.platforms.isDisjoint(with: p) && !(store && e.platforms.contains(.dmgOnly))
    }

    /// Questions about what is happening right now are answered by the tool-backed paths (they read the player, the guide, the playlists); the engine answers questions about the app itself.
    static let toolBacked: Set<AssistantIntent> = [.diagnosePlayback, .diagnoseGuide, .sourceHealth, .engineAdvice, .stats, .screen, .playbackControl, .unsupported]

    /// How a stored value is read when the catalogue has no reader for it.
    private static let readers: [String: (AppSettings) -> String] = [
        "iCloudSync": { $0.iCloudSync ? "on" : "off" }, "syncLogins": { $0.syncLogins ? "on" : "off" }, "lanSync": { $0.lanSync ? "on" : "off" }, "appLock": { $0.appLock ? "on" : "off" },
        "vpnPause": { $0.vpnPause ? "on" : "off" }, "proxyKind": { "\($0.proxyKind)" }, "appDNS": { $0.appDNS.enabled ? "on (\($0.appDNS.provider))" : "off" },
    ]

    static func current(_ e: AtlasEntry, settings: AppSettings) -> String? {
        guard let key = e.value?.settingKey else { return nil }
        if let c = AppSettingsCatalog.find(key), let r = c.read { return r(settings) }
        return readers[key]?(settings)
    }

    /// The reply for a question the engine can answer, or nil when it should go on to the tools and the optional model.
    static func reply(_ text: String, conversation: inout AtlasConversation, container c: AppContainer, misses: AtlasMisses = .shared) -> AtlasReply? {
        guard !c.parental.kidsMode else { return nil }
        let route = AssistantRouter.route(text)
        guard !toolBacked.contains(route) else {
            SetuRouterLog.decision(text: text, route: route, intent: .other, decision: .weak, confidence: 0, top: [], outcome: "tool-backed, engine skipped")
            return nil
        }
        let engine = Atlas.engine
        var scratch = conversation
        let a = engine.answer(text, conversation: &scratch, platform: platform, appStore: appStore, current: { current($0, settings: c.settings) })
        let r = engine.retrieve(text, platform: platform, appStore: appStore, limit: 3)
        // A question about the app is never sent on as a media search; with no model ready it gets the nearest topics instead of a dead end.
        let asksToPlay = text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("play ")
        let isQuestion = AssistantRouter.isAppHelp(text) || (SearchIntent.classify(text) == .ask && !asksToPlay)
        func log(_ outcome: String) { SetuRouterLog.decision(text: text, route: route, intent: a.intent, decision: a.decision, confidence: r.confidence, top: r.hits.map(\.entry.id), outcome: outcome) }
        func nearby() -> AtlasReply? {
            guard isQuestion, c.assistantModelChain().isEmpty else { return nil }
            misses.recordMiss(words: r.correctedQuery)
            return nearbyReply(for: text, engine: engine, container: c)
        }
        // A bare name or a phrase with no question in it ("bigg boss") is a library search unless the match is very strong.
        let detected = IntentDetector.detect(text)
        if detected.intent == .other, a.decision != .confident || r.confidence < 0.8 {
            if let n = nearby() { log("nearby topics (no cue, low confidence)"); return n }
            log("handed on (not a question or low confidence)"); return nil
        }
        guard a.decision != .weak else {
            if let n = nearby() { log("nearby topics (weak)"); return n }
            misses.recordMiss(words: r.correctedQuery)
            log("handed on (weak)"); return nil
        }
        conversation = scratch
        misses.recordAnswered()
        log("answered")
        return package(a, engine: engine, container: c)
    }

    /// The closest topics for a question Setu has no exact answer for: each is a chip, the first one with a screen also gets Open this, and the text says what Setu can do. Never a media search.
    static func nearbyReply(for text: String, engine: SetuEngine, container c: AppContainer) -> AtlasReply {
        let hits = engine.retrieve(text, platform: platform, appStore: appStore, limit: 6).hits.map(\.entry).filter { visible($0) }
        let a = Compose.fallback(Array(hits.prefix(3)), intent: IntentDetector.detect(text).intent)
        return package(a, engine: engine, container: c)
    }

    /// Turns an engine answer into the reply the assistant shows: every button is an ordinary proposal, rechecked by the authorizer when tapped. Also used for answers a model helped to pick.
    static func package(_ a: AtlasAnswer, engine: SetuEngine, container c: AppContainer) -> AtlasReply {
        var proposals: [AssistantProposal] = []
        var chips: [String] = []
        var chipIDs: [String] = []
        var showMe: [String] = []
        for action in a.actions {
            switch action.kind {
            case .openThis:
                if let e = engine.entry(action.entryID), e.reach != .none, visible(e) { proposals.append(AssistantProposal(kind: .openAtlas(id: e.id), origin: c.assistantOrigin())) }
            case .changeIt:
                guard let e = engine.entry(action.entryID), e.mayPropose, let key = e.value?.settingKey, let value = action.value,
                      let cat = AppSettingsCatalog.find(key), cat.changeable, cat.accepts(value) else { continue }
                proposals.append(AssistantProposal(kind: .setting(id: cat.id, value: value.lowercased()), origin: c.assistantOrigin()))
            case .pick:
                chips.append(action.label); chipIDs.append(action.entryID)
            case .showMe:
                // Offered for any entry a person can see: with a marker it points at the control, without one it degrades to "open the screen first".
                if let e = engine.entry(action.entryID), visible(e), !showMe.contains(e.id) { showMe.append(e.id) }
            }
        }
        // When a change is on offer, that is the button; "Open this" beside it would only be a second way to the same place.
        if proposals.contains(where: { if case .setting = $0.kind { true } else { false } }) { proposals.removeAll { if case .openAtlas = $0.kind { true } else { false } } }
        var reply = AtlasReply(text: a.text, proposals: proposals, chips: chips, decision: a.decision, entryIDs: a.entryIDs, showMe: showMe)
        reply.chipIDs = chipIDs
        return reply
    }

    /// The answer for a chip: the entry's own answer by id, with no search, no intent guessing and no model.
    static func entryReply(id: String, conversation: inout AtlasConversation, container c: AppContainer) -> AtlasReply? {
        guard !c.parental.kidsMode, let e = Atlas.entry(id), visible(e) else { return nil }
        let a = Compose.compose(intent: .howDoI, entry: e, platform: platform, current: current(e, settings: c.settings), value: nil)
        conversation.remember(entries: [e.id], intent: .howDoI, platform: platform, now: Date())
        return package(a, engine: Atlas.engine, container: c)
    }

    /// What find_setting returns: the closest settings with their current value and choices. A setting the model may change carries its catalogue id for change_setting.
    static func findSettings(_ query: String, settings: AppSettings, limit: Int = 5) -> String {
        let r = Atlas.engine.retrieve(query, platform: platform, appStore: appStore, limit: 25)
        var out: [String] = []
        for h in r.hits where h.entry.kind == .setting {
            let e = h.entry
            if let key = e.value?.settingKey, let cat = AppSettingsCatalog.find(key), cat.changeable, !e.guideOnly {
                out.append(AppSettingsCatalog.describe(cat, settings) + "\n   " + e.summary + (e.detail.map { " " + $0 } ?? ""))
                continue
            }
            var t = "\(e.title) (id: \(e.id)) | where: \(e.path.joined(separator: " > "))"
            if let now = current(e, settings: settings) { t += " | now: \(now)" }
            if let o = e.value?.options, !o.isEmpty { t += " | options: " + o.joined(separator: ", ") }
            t += " | can change: no (explain where to find it)\n   " + e.summary + (e.detail.map { " " + $0 } ?? "")
            out.append(t)
            if out.count >= limit { break }
        }
        return out.prefix(limit).joined(separator: "\n")
    }

    /// What find_help returns: the closest screens, how-tos, menu items, shortcuts and fixes, with the id open_screen accepts.
    static func findHelp(_ query: String, limit: Int = 3) -> String {
        let r = Atlas.engine.retrieve(query, platform: platform, appStore: appStore, limit: 25)
        var out: [String] = []
        for h in r.hits where h.entry.kind != .setting {
            let e = h.entry
            var t = "\(e.title) (id: \(e.id)) | where: \(e.path.joined(separator: " > "))"
            if let k = e.shortcut { t += " | shortcut: \(k)" }
            t += "\n" + e.summary + (e.detail.map { " " + $0 } ?? "")
            if let steps = e.recipe, !steps.isEmpty { t += "\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element.say)" }.joined(separator: "\n") }
            out.append(t)
            if out.count >= limit { break }
        }
        return out.joined(separator: "\n\n")
    }

    /// Candidate topics for a model that is asked only when the engine was unsure. It must pick from these and not invent screens or settings.
    static func candidates(for text: String, limit: Int = 5) -> String? {
        let r = Atlas.engine.retrieve(text, platform: platform, appStore: appStore, limit: limit)
        // A bare name or a request for something to watch is not a question about the app: nothing to offer.
        guard !r.hits.isEmpty, r.intent != .other || r.confidence >= 0.3 else { return nil }
        let lines = r.hits.map { h -> String in
            let e = h.entry
            return "- \(e.id) | \(e.title) | \(e.path.joined(separator: " > ")) | \(e.summary)"
        }
        return "The app's own index of its screens, settings and how-tos found these closest topics for the question. Answer from them; do not name a screen or setting that is not listed here or returned by find_setting or find_help.\n" + lines.joined(separator: "\n")
    }

    /// The text for "I could not tell what you meant" when no model is available: closest topics and what Setu can do.
    static func fallbackText(for text: String) -> String {
        let r = Atlas.engine.retrieve(text, platform: platform, appStore: appStore, limit: 3)
        return Compose.fallback(r.hits.map(\.entry), intent: r.intent).text
    }
}
