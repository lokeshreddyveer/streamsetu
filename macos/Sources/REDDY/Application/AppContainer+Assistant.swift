import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The assistant's eyes and hands: what it is told about the moment, the lookups it may use, and how a confirmed suggestion is carried out.
extension AppContainer {
    /// Whether the person lets the assistant see the screen, what is playing and a few library numbers. On by default; the panel says so and can switch it off.
    var assistantSeesScreen: Bool {
        get { settings.defaultsStore.object(forKey: "assistant.context") as? Bool ?? true }
        set { settings.defaultsStore.set(newValue, forKey: "assistant.context") }
    }

    /// Whether the words after the verb are exactly a title or channel in the library ("play Something Wicked"), in which case it is that title and not a vague request.
    @MainActor func assistantNamesATitle(_ text: String) -> Bool {
        for c in SearchCommands.parse(text) {
            guard case .play(let name) = c.kind else { continue }
            let wanted = MetadataNormalizer.normalize(TraktItem.cleanTitle(name))
            let hit = SearchCommandRunner.find(name, in: self)
            if let item = hit.item, MetadataNormalizer.normalize(TraktItem.cleanTitle(item.title)) == wanted { return true }
            if let ch = hit.channel, MetadataNormalizer.normalize(ch.name) == wanted { return true }
        }
        return false
    }

    /// What a typed command offers, after checking the library: "play X" only becomes a button when X exists, and then it is that exact title or channel. Words that are not a title ("play something",
    /// "play something best series") are not commands at all: nil, so the request goes to the search and the AI like any other.
    @MainActor func assistantCommandProposals(_ text: String) -> [AssistantProposal]? {
        // a request for something to watch is not a command about a title (unless the library really has a title of exactly those words)
        if AssistantDiscovery.parse(text) != nil, !assistantNamesATitle(text) { return nil }
        let commands = SearchCommands.parse(text)
        guard !commands.isEmpty else { return nil }
        var out: [AssistantProposal] = []
        for c in commands {
            switch c.kind {
            case .go, .resume, .lastChannel: out.append(AssistantProposal(kind: .command(c), origin: assistantOrigin()))
            case .play(let name):
                let hit = SearchCommandRunner.find(name, in: self)
                if let item = hit.item { out.append(AssistantProposal(kind: .playItem(id: item.id, isChannel: false, title: item.title), origin: assistantOrigin(item: item))) }
                else if let ch = hit.channel {
                    var o = assistantOrigin(); o.targetItemID = ch.id; o.categoryID = ch.categoryID
                    out.append(AssistantProposal(kind: .playItem(id: ch.id, isChannel: true, title: ch.name), origin: o))
                }
            case .favourite(let name, let on), .watchLater(let name, let on):
                guard let item = SearchCommandRunner.find(name, in: self).item else { continue }
                var later = false; if case .watchLater = c.kind { later = true }
                out.append(AssistantProposal(kind: .toggleList(id: item.id, kind: item.kind, watchLater: later, on: on, title: item.title), origin: assistantOrigin(item: item)))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Whether a folder's contents may be used right now. Asked again at the moment of running, from the live parental state, not from what was true when the offer was made.
    @MainActor func assistantAccessAllowed(categoryID: String?) -> Bool {
        AssistantAuthorizer.accessAllowed(categoryID: categoryID, restricting: parental.isRestricting, isLocked: { parental.isLocked($0) })
    }

    /// Who an offer is for and what it concerns, noted when it is made and rechecked when it is tapped.
    @MainActor func assistantOrigin(item: LibraryItem? = nil) -> AssistantProposal.Origin {
        AssistantProposal.Origin(profileID: profiles.activeID, createdAt: Date(), playbackKey: playback.current?.itemID, targetItemID: item?.id, categoryID: item?.categoryID)
    }

    /// A title as the assistant sees it: facts only, from the library on this device.
    func assistantDescribe(_ item: LibraryItem) -> String {
        var parts = [item.title, item.isSeries ? "series" : "movie"]
        if let y = item.year { parts.append(String(y)) }
        if let g = item.genre, !g.isEmpty { parts.append(g) }
        let rating: String? = { switch item { case .movie(let m): m.rating; case .series(let t): t.rating } }()
        if let r = rating, !r.isEmpty, r != "0" { parts.append("rated \(r)") }
        var s = parts.joined(separator: ", ")
        if let plot = item.overview, !plot.isEmpty { s += ". Plot: " + String(plot.prefix(300)) }
        let cast = PeopleIndex(db: db).names(forItems: [item.id])[item.id] ?? []
        if !cast.isEmpty { s += ". Cast: " + cast.prefix(8).joined(separator: ", ") }
        return s
    }

    /// Where the person is and what is going on. Built fresh for each message.
    func assistantContext(screen: String, openItem: LibraryItem?, searchText: String?) -> AssistantContext {
        var c = AssistantContext()
        c.screen = screen
        c.searchText = searchText
        if let openItem { c.openItem = assistantDescribe(openItem) }
        if playback.current != nil {
            var p = playback.title
            if playback.isLive, let ch = playback.currentChannel,
               let nn = (try? epgRepo.nowNext(channelIDs: [ch.id], at: Date()))?[ch.id], let now = nn.first {
                p += " (live; now: \(now.title)" + (nn.count > 1 ? ", next: \(nn[1].title)" : "") + ")"
            }
            switch playback.state {
            case .paused: p += " [paused]"
            case .buffering: p += " [buffering]"
            case .failed(let e): p += " [failed: \(e.localizedDescription)]"
            default: break
            }
            if let m = playback.statusMessage, !m.isEmpty { p += " [\(m)]" }
            c.nowPlaying = p
        }
        let counts = (try? db.read { d in (try d.scalarInt("SELECT COUNT(*) FROM channels"), try d.scalarInt("SELECT COUNT(*) FROM movies"), try d.scalarInt("SELECT COUNT(*) FROM series")) }) ?? (0, 0, 0)
        let sources = (try? catalog.sources().filter(\.enabled).count) ?? 0
        c.library = "\(sources) playlist(s), \(counts.0) channels, \(counts.1) movies, \(counts.2) series"
        let taste = TasteProfile.learn(history: historyRepo, catalog: catalog, people: PeopleIndex(db: db))
        if taste.isUsable {
            let g = taste.genres.sorted { $0.value > $1.value }.prefix(3).map(\.key), l = taste.languages.sorted { $0.value > $1.value }.prefix(2).map(\.key)
            c.taste = (g + l).joined(separator: ", ")
        }
        return c
    }

    /// Whether the assistant may use online AI services. Off means only the on-device model (and your own Ollama), with the app's own reading for everything else.
    var assistantCloudAllowed: Bool {
        get { settings.defaultsStore.object(forKey: "assistant.cloud") as? Bool ?? true }
        set { settings.defaultsStore.set(newValue, forKey: "assistant.cloud") }
    }

    /// The models to try, in order: the chosen one, then the others that are ready (on-device first, then online ones if allowed), so a rate limit or an outage does not end the conversation.
    func assistantModelChain() -> [AIConfig] {
        let chosen = ai.load()
        let order: [AIProvider] = [.apple, .gemini, .groq, .openRouter, .nvidia, .ollamaCloud, .claude, .openAI, .ollama]
        func allowed(_ p: AIProvider) -> Bool { assistantCloudAllowed || p == .apple || p == .ollama }
        var chain: [AIConfig] = chosen.isReady && allowed(chosen.provider) ? [chosen] : []
        for p in order where p != chosen.provider && allowed(p) && (p == .apple ? AIClient.appleAvailability().ok : ai.load(p).isReady) { chain.append(ai.load(p)) }
        return chain
    }

    nonisolated static func isTransient(_ e: AIError) -> Bool {
        let m = e.localizedDescription.lowercased()
        return m.contains("not answering") || m.contains("does not know the model") || m.contains("could not be read") || m.contains("network") || m.contains("timed out")
    }

    /// Asks the assistant. The words are routed by plain rules first; what the app already knows about a problem (a playback diagnosis, a guide check) is handed to the AI as evidence to explain.
    /// With no AI available, the same evidence is answered directly. A model that fails is replaced by the next one.
    /// `skipInstant` hands a name to the AI even though the app's own search found something (the person said that was not what they meant).
    func askAssistant(history: [(person: Bool, text: String)], context: AssistantContext?, onStep: @escaping @MainActor (String) -> Void, skipInstant: Bool = false) async throws -> AssistantReply {
        guard !parental.kidsMode else { throw AIError.unavailable("The assistant is not available in a kids profile.") }
        let text = history.last?.text ?? ""
        // A name on its own is answered by the app's own search at once; no model is waited for.
        if !skipInstant, let found = await AssistantToolbox(container: self, onStep: onStep).discoveryReply(text) { return found }
        if !skipInstant, let fast = await AssistantToolbox(container: self, onStep: onStep).fastNameReply(text) { return fast }
        let hint = skipInstant ? "The person says the quick search results for this name were not what they meant. Look beyond them: it may be a person, another spelling, another language, a mood or something else. Check anything you suggest with the library tools." : nil
        var chain = assistantModelChain()
        var handedOver: String?
        // Apple's on-device model does not know actors and films well. For a question about a person, an online model that is ready goes first.
        if chain.first?.provider == .apple, chain.count > 1, AssistantRouter.route(text) == .general {
            let local = LocalIntent.parse(text) { PeopleIndex(db: self.db).canonicalName(for: $0) }
            if !local.people.isEmpty {
                let better = chain.filter { $0.provider != .apple }
                handedOver = better.first?.provider.title
                chain = better + chain.filter { $0.provider == .apple }
            }
        }
        guard !chain.isEmpty else { return await AssistantToolbox(container: self, onStep: onStep).localReply(text) }
        var failures: [String] = []
        for (i, config) in chain.enumerated() {
            do {
                var r: AssistantReply
                do { r = try await AssistantAgent.run(history: history, context: context, client: AIClient(config: config), toolbox: AssistantToolbox(container: self, onStep: onStep), hint: hint) }
                catch let e as AIError where Self.isTransient(e) {          // a blip (a server hiccup, a model briefly "unknown"): once more before moving on
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    r = try await AssistantAgent.run(history: history, context: context, client: AIClient(config: config), toolbox: AssistantToolbox(container: self, onStep: onStep), hint: hint)
                }
                if i > 0 { r.usedModel = config.provider.title; r.fallbackNote = failures.last.map { "\($0) so " + config.provider.title + " answered." } }
                else if let h = handedOver { r.fallbackNote = "Apple Intelligence does not know actors well, so \(h) answered this one." }
                return r
            } catch let e as AIError {
                failures.append("\(chain[i].provider.title): " + e.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(90))
                if case .notConfigured = e { continue }
            } catch { failures.append(chain[i].provider.title + " could not answer") }
        }
        // Nothing answered: the app's own reading still helps.
        var r = await AssistantToolbox(container: self, onStep: onStep).localReply(text)
        r.fallbackNote = "No AI could answer (\(failures.first ?? "unavailable")). This is the app's own answer."
        return r
    }

    /// Carries out a confirmed suggestion that does not need a screen to change (settings, playback, refresh). Returns a sentence for the person.
    @MainActor func perform(_ p: AssistantProposal, state: AppState) async -> AssistantOutcome {
        switch p.kind {
        case .setting(let id, let value):
            guard let e = AppSettingsCatalog.find(id), e.changeable else { return .failed("That setting cannot be changed from here.") }
            guard let r = applySetting(id: id, value: value) else { return .failed("That value is not allowed for \(e.title).") }
            return .done("Done: \(e.title) is now \(r.now)." + (r.note.map { " " + $0 } ?? ""))
        case .refresh:
            state.syncAll(); return .done("Refreshing your playlists.")
        case .playback(let a):
            guard playback.current != nil else { return .failed("Nothing is playing.") }
            switch a {
            case "pause": playback.pause()
            case "play": playback.resume()
            case "mute": playback.isMuted = true
            case "unmute": playback.isMuted = false
            case "volume_up": playback.isMuted = false; playback.volume = min(1, playback.volume + 0.1)
            case "volume_down": playback.volume = max(0, playback.volume - 0.1)
            case "forward": playback.seek(by: 30)
            case "back": playback.seek(by: -15)
            case "next_episode": playback.playNextEpisode()
            case "stop": playback.stop()
            default: return .failed("That is not something I can do.")
            }
            return .done(AssistantPlayback.title(a) + " done.")
        case .retry:
            guard let cur = playback.current else { return .failed("Nothing is playing.") }
            playback.retryNow()
            let out = await AssistantPlaybackWatch.started(playback, expecting: cur.itemID)
            return out.isDone ? .done("Playing again.") : out
        case .engine(let key):
            // "Automatic" is a saved preference. Restarting the stream is a separate, explicit action (Try again).
            if key == "auto" { settings.enginePreference = .automatic; return .done("The player engine is set to Automatic. It applies from the next stream; use “Try again” to restart this one.") }
            let kind: PlaybackEngineKind = key == "mpv" ? .mpv : .avPlayer
            guard playback.availableEngines.contains(kind) else { return .failed("\(kind.rawValue) is not available on this device.") }
            guard let cur = playback.current else { return .failed("Nothing is playing to switch.") }
            playback.switchEngine(kind)
            let out = await AssistantPlaybackWatch.started(playback, expecting: cur.itemID)
            return out.isDone ? .done("Switched to \(kind.rawValue) and it is playing.") : out
        case .track(let audio, let id, let label):
            guard playback.current != nil else { return .failed("Nothing is playing.") }
            if audio { playback.selectAudio(id) } else { playback.selectSubtitle(id) }
            return .done(id == nil ? "Subtitles are off." : "Using \(label).")
        case .syncGuide:
            state.refreshGuides(); return .done("Refreshing the guide of every playlist that is on.")
        case .copyReport(let text):
            #if canImport(AppKit)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            #elseif canImport(UIKit)
            UIPasteboard.general.string = text
            #endif
            return .done("Copied. It has no logins, addresses or tokens, so it is safe to share.")
        case .command, .playItem, .toggleList: return .failed("That is carried out by the screen's own runner.")      // see SearchCommandRunner.execute
        }
    }
}

/// A short summary from Wikipedia for a topic. Only the words searched for are sent, and nothing is kept.
enum WikipediaLookup {
    static func summary(of topic: String) async -> String? {
        let q = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, var search = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return nil }
        search.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"), .init(name: "srsearch", value: q), .init(name: "srlimit", value: "1"), .init(name: "format", value: "json")]
        guard let url = search.url, let data = try? await fetch(url),
              let title = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["query"] as? [String: Any]).flatMap({ ($0["search"] as? [[String: Any]])?.first?["title"] as? String }),
              let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))), let sURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/" + encoded),
              let sData = try? await fetch(sURL), let extract = ((try? JSONSerialization.jsonObject(with: sData)) as? [String: Any])?["extract"] as? String, !extract.isEmpty else { return nil }
        return "Wikipedia, \(title): " + String(extract.prefix(700))
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url); r.timeoutInterval = 10; r.setValue("StreamSetu", forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }
}
