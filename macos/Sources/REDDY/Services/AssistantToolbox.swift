import Foundation

/// The assistant's tools: what it can look up (all from this device, except Wikipedia) and what it can offer to do. Each returns plain text for the model to read. Nothing here changes anything:
/// an action is recorded as a proposal and the person taps to confirm.
@MainActor final class AssistantToolbox {
    let container: AppContainer
    private let onStep: @MainActor (String) -> Void
    private(set) var proposals: [AssistantProposal] = []
    private(set) var lastAnswer: AskAnswer?
    private(set) var stepsTaken: [String] = []
    /// What the last look-up by name found, in a few words ("2 live channels, 3 series").
    private(set) var lastEverything: String?
    /// What the person lets the assistant see (nil when screen sharing is off).
    var context: AssistantContext?

    init(container: AppContainer, onStep: @escaping @MainActor (String) -> Void = { _ in }) { self.container = container; self.onStep = onStep }

    // MARK: what the model is told it may use

    func specs(compact: Bool) -> [AITool] {
        func s(_ n: String, _ h: String) -> AIToolParam { .init(name: n, kind: .string, help: h) }
        func o(_ n: String, _ h: String) -> AIToolParam { .init(name: n, kind: .string, help: h, required: false) }
        var t: [AITool] = [
            AITool(name: "search_everything", help: "Search EVERYTHING for a name or title the way the app's search box does: live channels, movies, series, episodes and the TV guide, across all playlists. Use this first whenever the person types or asks about a name (a show, film, channel or actor), even a misspelt or run-together one.", params: [s("query", "The name or title")]),
            AITool(name: "search_library", help: "Find titles in the person's own library from a plain request: genre, language, year, mood, a person, 'unwatched', 'under 2 hours', 'top rated'. Also reads the cast index.", params: [s("query", "The request in plain words"), o("kind", "movies, series or any")]),
            AITool(name: "check_library", help: "THE BRIDGE FROM A DESCRIPTION TO WHAT THEY HAVE. Give it the real titles you have chosen (from your own knowledge, or from web_lookup) for a request like 'best horror movies', 'Netflix top movies', 'Marvel in order', 'films like Athadu' or an actor's films. Put them in the order you recommend them, each as 'Title (Year)' (add alternate spellings after ' / '). It matches every one against the app's own search and returns which are in the library (shown to the person as cards, in your order) and which are not.", params: [.init(name: "titles", kind: .strings, help: "Titles in recommended order, like 'Pokiri (2006)' or 'Drishyam (2013) / Drushyam'")]),
            AITool(name: "title_details", help: "Plot, genre, rating and cast of a title in the library.", params: [s("title", "The title")]),
            AITool(name: "tv_guide", help: "What is on TV: a programme name (finds when it airs) or a channel name (what is on it now and next).", params: [s("query", "Programme or channel")]),
            AITool(name: "diagnose_playback", help: "Work out why the current stream is buffering, failing, silent or not starting, from the player's real numbers and its last error. Separates app, provider, network, credential, format and device causes, and offers the fix.", params: []),
            AITool(name: "source_health", help: "Check a playlist: what it holds, when it last refreshed, any error, and whether its server answers. Safe: it sends no login.", params: [o("source", "Playlist name, or leave empty for all")]),
            AITool(name: "guide_status", help: "Why the TV guide is empty, partial or out of date, for a playlist.", params: [o("source", "Playlist name, or leave empty for all")]),
            AITool(name: "recommend_engine", help: "Which player engine (Apple AVPlayer or MPV) suits what is playing, and why.", params: []),
            AITool(name: "source_setup_help", help: "Step-by-step help adding a playlist or source: Xtream, M3U link, M3U file, Jellyfin, Emby, Plex, Stalker, HDHomeRun.", params: [s("type", "Which kind")]),
            AITool(name: "now_playing", help: "Everything about what is playing: state, position, engine, resolution, bitrate, dropped frames, stalls, buffer, tracks. Use it to explain a playback problem.", params: []),
            AITool(name: "find_setting", help: "Look up the app's settings by topic: what each does, its choices, its current value, where it is, and whether you can change it.", params: [s("query", "Topic, e.g. 'subtitles' or 'buffering'")]),
            AITool(name: "find_help", help: "How-to knowledge about the app's features (search, favourites, recording, playlists, privacy, fixing playback…).", params: [s("topic", "What they want to do")]),
            AITool(name: "change_setting", help: "Offer to change one setting. Use find_setting first for the exact id and value. The person taps to confirm.", params: [s("id", "Setting id"), s("value", "New value: on, off, or one of its options")]),
            AITool(name: "control_playback", help: "Offer a button to control what is playing.", params: [.init(name: "action", kind: .oneOf(AssistantPlayback.actions), help: "The action")]),
            AITool(name: "open_screen", help: "Offer a button to go to a screen, optionally with a filter sentence for Movies, Series or Live TV (e.g. 'top rated telugu').", params: [.init(name: "target", kind: .oneOf(CommandTarget.allCases.map(\.rawValue)), help: "Screen"), o("filter", "Filter words")]),
            AITool(name: "play_title", help: "Offer a button to play a movie, series or channel from the library.", params: [s("title", "Title or channel")]),
            AITool(name: "retry_playback", help: "Offer a button to restart the current stream.", params: []),
            AITool(name: "switch_engine", help: "Offer a button to switch the player engine for what is playing.", params: [.init(name: "engine", kind: .oneOf(["mpv", "avPlayer", "automatic"]), help: "Engine")]),
            AITool(name: "select_track", help: "Offer a button to choose an audio or subtitle track of what is playing (by language or name), or turn subtitles off.", params: [.init(name: "kind", kind: .oneOf(["audio", "subtitle"]), help: "Track kind"), s("choice", "Language or name, or 'off' for subtitles")]),
            AITool(name: "sync_guide", help: "Offer a button to refresh the TV guide.", params: []),
            AITool(name: "problem_report", help: "Prepare a redacted problem report (no logins, addresses or tokens) and offer to copy it.", params: []),
            AITool(name: "web_lookup", help: "A short summary from Wikipedia about a film, series, actor or topic.", params: [s("topic", "Topic")]),
            AITool(name: "web_titles", help: "The titles Wikipedia lists on the filmography page of a person (an actor, director) or franchise: plain names, to hand to check_library. Say that they came from Wikipedia, not from your memory.", params: [s("person", "The person or franchise")]),
        ]
        if !compact {
            t += [
                AITool(name: "similar_titles", help: "Titles in the library similar to one the person likes.", params: [s("title", "The title")]),
                AITool(name: "watch_stats", help: "How much the person watched, and their top channel, movie and series.", params: [.init(name: "period", kind: .oneOf(["week", "month", "all"]), help: "Period")]),
                AITool(name: "favourite", help: "Offer to add or remove a title from Favorites.", params: [s("title", "Title"), .init(name: "on", kind: .boolean, help: "true to add, false to remove")]),
                AITool(name: "watch_later", help: "Offer to add or remove a title from Watch Later.", params: [s("title", "Title"), .init(name: "on", kind: .boolean, help: "true to add, false to remove")]),
                AITool(name: "resume_watching", help: "Offer a button to resume the most recent partly watched title.", params: []),
                AITool(name: "refresh_playlists", help: "Offer a button to refresh all playlists.", params: []),
            ]
        }
        // The most useful first: the on-device model has a small window, so it gets only the first few.
        let order = ["search_everything", "check_library", "diagnose_playback", "source_health", "guide_status", "find_setting", "find_help", "change_setting", "control_playback", "play_title", "tv_guide",
                     "search_library", "open_screen", "title_details", "recommend_engine", "now_playing", "switch_engine", "select_track", "retry_playback", "sync_guide", "source_setup_help", "problem_report", "web_lookup", "web_titles"]
        t.sort { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
        return compact ? Array(t.prefix(10)) : t
    }

    private func step(_ n: String) {
        let text: String
        switch n {
        case "search_everything": text = "Searching channels, movies, series and the guide…"
        case "search_library": text = "Looking in your library…"
        case "check_library": text = "Checking your library for those titles…"
        case "title_details", "similar_titles": text = "Reading about that title…"
        case "tv_guide": text = "Checking the TV guide…"
        case "now_playing", "diagnose_playback", "recommend_engine": text = "Looking at the player…"
        case "source_health": text = "Checking the playlist…"
        case "guide_status": text = "Checking the guide…"
        case "source_setup_help": text = "Looking that up…"
        case "find_setting": text = "Looking up the settings…"
        case "find_help": text = "Looking that up…"
        case "web_lookup", "web_titles": text = "Reading Wikipedia…"
        case "watch_stats": text = "Adding up your viewing…"
        default: text = "Working on it…"
        }
        if !stepsTaken.contains(text) { stepsTaken.append(text) }
        onStep(text)
    }

    // MARK: running a tool

    func run(_ name: String, _ a: AIArgs) async -> String {
        step(name)
        let c = container
        func str(_ k: String) -> String { (a[k]?.text ?? a[k]?.list.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch name {
        case "search_everything": return await searchEverything(str("query"))
        case "search_library": return await searchLibrary(str("query"), kind: str("kind"))
        case "check_library": return checkLibrary(a["titles"]?.list ?? [])
        case "title_details":
            guard let item = SearchCommandRunner.find(str("title"), in: c).item else { return "“\(str("title"))” is not in the library." }
            return c.assistantDescribe(item)
        case "similar_titles":
            guard let seed = SearchCommandRunner.find(str("title"), in: c).item else { return "“\(str("title"))” is not in the library." }
            let list = SimilarService(catalog: c.catalog).suggestions(for: seed, extras: nil).prefix(10).map(\.item.title)
            return list.isEmpty ? "Nothing similar found." : "Similar titles in the library: " + list.joined(separator: "; ")
        case "tv_guide": return tvGuide(str("query"))
        case "now_playing": return nowPlaying()
        case "diagnose_playback": return present(AssistantDiagnostics.playback(c.playbackEvidence()))
        case "recommend_engine":
            let e = c.playbackEvidence()
            return present(AssistantDiagnostics.engineAdvice(container: e.container, current: e.engine, preference: e.enginePreference, available: e.availableEngines, hadFormatError: e.failure?.kind == .unsupportedFormat))
        case "source_health":
            let list = c.assistantSources(matching: str("source"))
            guard !list.isEmpty else { return "There are no playlists yet." }
            var findings: [AssistantFinding] = []
            for src in list.prefix(4) { findings.append(AssistantDiagnostics.sourceHealth(await c.sourceEvidence(for: src, probe: true))) }
            return findings.map { present($0) }.joined(separator: "\n\n---\n\n")
        case "guide_status":
            let list = c.assistantSources(matching: str("source")).filter(\.enabled)
            guard !list.isEmpty else { return "There are no playlists yet." }
            return list.prefix(4).map { present(AssistantDiagnostics.guide(c.guideEvidence(for: $0))) }.joined(separator: "\n\n---\n\n")
        case "source_setup_help": return sourceSetup(str("type"))
        case "retry_playback":
            guard c.playback.current != nil else { return "Nothing is playing to retry." }
            propose(.retry); return "Offered: try again. The person must tap the button."
        case "switch_engine":
            let e = str("engine").lowercased()
            guard ["mpv", "avplayer", "automatic"].contains(e) else { return "Unknown engine." }
            let key = e == "automatic" ? "auto" : e == "mpv" ? "mpv" : "avPlayer"
            if key == "mpv", !c.playback.availableEngines.contains(.mpv) { return "MPV is not available on this device." }
            propose(.engine(key)); return "Offered: engine \(e). The person must tap the button."
        case "select_track":
            let audio = str("kind") == "audio", want = str("choice").lowercased()
            if !audio, ["off", "none", "no"].contains(want) { propose(.track(audio: false, id: nil, label: "Off")); return "Offered: subtitles off." }
            let tracks: [(id: String, label: String, lang: String?)] = audio ? c.playback.audioTracks.map { ($0.id, $0.label, $0.language) } : c.playback.subtitleTracks.map { ($0.id, $0.label, $0.language) }
            guard c.playback.current != nil else { return "Nothing is playing." }
            guard let t = tracks.first(where: { $0.label.lowercased().contains(want) || ($0.lang ?? "").lowercased().hasPrefix(want) }) else { return "No \(audio ? "audio" : "subtitle") track matches “\(want)”. Available: " + (tracks.map(\.label).joined(separator: ", ").isEmpty ? "none" : tracks.map(\.label).joined(separator: ", ")) }
            propose(.track(audio: audio, id: t.id, label: t.label)); return "Offered: \(t.label). The person must tap the button."
        case "sync_guide": propose(.syncGuide); return "Offered: refresh the guide. The person must tap the button."
        case "problem_report":
            let report = c.diagnostics.report(playback: c.playback.current == nil ? nil : c.playback.title, engines: c.playback.availableEngines.map(\.rawValue))
            propose(.copyReport(report)); return "A report is ready with logins, addresses and tokens removed (\(report.count) characters). Offered a button to copy it."
        case "find_setting":
            let hits = AppSettingsCatalog.search(str("query"), limit: 5)
            return hits.isEmpty ? "No matching setting. Try find_help." : hits.map { AppSettingsCatalog.describe($0, c.settings) }.joined(separator: "\n")
        case "find_help":
            let hits = AppGuide.search(str("topic"), limit: 2)
            return hits.isEmpty ? "No how-to article for that." : hits.map { "\($0.title): \($0.body)" }.joined(separator: "\n\n")
        case "web_lookup": return await WikipediaLookup.summary(of: str("topic")) ?? "Wikipedia had nothing on that."
        case "web_titles": return await WikipediaLookup.titles(of: str("person")) ?? "Wikipedia had no filmography page for that."
        case "watch_stats": return stats(str("period"))
        case "change_setting":
            guard let e = AppSettingsCatalog.find(str("id")) else { return "Unknown setting id. Use find_setting to get one." }
            guard e.changeable else { return "\(e.title) cannot be changed by you. Tell the person where it is: \(e.path)." }
            let value = str("value")
            guard e.accepts(value) else { return "“\(value)” is not allowed for \(e.title). Options: " + (e.options.isEmpty ? "see find_setting" : e.options.joined(separator: ", ")) + "." }
            propose(.setting(id: e.id, value: value.lowercased()))
            return "Offered: set \(e.title) to \(value). The person must tap the button; it is not done yet."
        case "control_playback":
            let act = str("action")
            guard AssistantPlayback.actions.contains(act) else { return "Unknown action." }
            guard c.playback.current != nil else { return "Nothing is playing, so there is nothing to control." }
            propose(.playback(act)); return "Offered: \(AssistantPlayback.title(act)). The person must tap the button."
        case "open_screen":
            guard let t = CommandTarget(rawValue: str("target")) else { return "Unknown screen." }
            let f = str("filter")
            propose(.command(.init(kind: .go(t, library: f.isEmpty ? nil : f)))); return "Offered: open \(t.title). The person must tap the button."
        case "play_title":
            let hit = SearchCommandRunner.find(str("title"), in: c)
            if let item = hit.item { propose(.playItem(id: item.id, isChannel: false, title: item.title), item: item); return "Offered: play \(item.title). The person must tap the button." }
            if let ch = hit.channel { propose(.playItem(id: ch.id, isChannel: true, title: ch.name), categoryID: ch.categoryID, targetID: ch.id); return "Offered: play \(ch.name). The person must tap the button." }
            return "“\(str("title"))” is not in the library."
        case "favourite", "watch_later":
            guard let item = SearchCommandRunner.find(str("title"), in: c).item else { return "“\(str("title"))” is not in the library." }
            let on = a["on"]?.flag ?? true
            propose(.toggleList(id: item.id, kind: item.kind, watchLater: name == "watch_later", on: on, title: item.title), item: item)
            return "Offered. The person must tap the button."
        case "resume_watching":
            propose(.command(.init(kind: .resume))); return "Offered: resume watching. The person must tap the button."
        case "refresh_playlists":
            propose(.refresh); return "Offered: refresh playlists. The person must tap the button."
        default: return "Unknown tool."
        }
    }

    /// Records an offer, with who it was for and what it concerns, so it can be rechecked when tapped.
    private func propose(_ k: AssistantProposal.Kind, item: LibraryItem? = nil, categoryID: String? = nil, targetID: String? = nil) {
        var o = container.assistantOrigin(item: item)
        if let categoryID { o.categoryID = categoryID }
        if let targetID { o.targetItemID = targetID }
        let p = AssistantProposal(kind: k, origin: o)
        // the same offer made twice (by the app's own look-up and then by the model) is shown once
        guard !proposals.contains(where: { $0.title == p.title && AssistantActions.spec(for: $0.kind).id == AssistantActions.spec(for: p.kind).id }) else { return }
        proposals.append(p)
    }

    /// A finding as text for the model, with its buttons offered to the person.
    private func present(_ f: AssistantFinding) -> String { "Cause: \(f.cause.rawValue)\n" + presentText(f) }

    /// The evidence for a request the rules recognise (a playback problem, an empty guide, a playlist check, an engine question), gathered before any model is asked, with its buttons offered.
    func preload(_ intent: AssistantIntent, text: String) async -> String? {
        let c = container
        switch intent {
        case .diagnosePlayback: step("diagnose_playback"); return presentText(AssistantDiagnostics.playback(c.playbackEvidence()))
        case .diagnoseGuide:
            step("guide_status")
            let list = c.assistantSources(matching: "").filter(\.enabled)
            return list.isEmpty ? nil : list.prefix(3).map { presentText(AssistantDiagnostics.guide(c.guideEvidence(for: $0))) }.joined(separator: "\n\n---\n\n")
        case .sourceHealth:
            step("source_health")
            let list = c.assistantSources(matching: "")
            guard !list.isEmpty else { return nil }
            var out: [String] = []
            for src in list.prefix(4) { out.append(presentText(AssistantDiagnostics.sourceHealth(await c.sourceEvidence(for: src, probe: true)))) }
            return out.joined(separator: "\n\n---\n\n")
        case .engineAdvice:
            step("recommend_engine")
            let e = c.playbackEvidence()
            return presentText(AssistantDiagnostics.engineAdvice(container: e.container, current: e.engine, preference: e.enginePreference, available: e.availableEngines, hadFormatError: e.failure?.kind == .unsupportedFormat))
        case .addSource: step("source_setup_help"); return sourceSetup(AssistantRouter.sourceKind(in: text) ?? "")
        case .privacy:
            step("find_help")
            return AppGuide.articles.filter { $0.title == "Where StreamSetu keeps things" || $0.title == "Privacy and safety" }.map(\.body).joined(separator: "\n\n")
        case .screen: return screenAnswer()
        case .stats:
            step("watch_stats")
            let l = text.lowercased()
            return "Viewing numbers: " + stats(l.contains("month") ? "month" : l.contains("all time") || l.contains("ever") || l.contains("total") ? "all" : "week")
        case .general:
            // A bare name ("bigg boss", "mahesh babu movies"): look it up everywhere first, so any model, even a small one, answers from what is really there.
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard (1...5).contains(words.count), words.allSatisfy({ !Self.notAName.contains($0) && !Self.describesAList.contains($0) }), text.count >= 3 else { return nil }
            step("search_everything")
            let found = await searchEverything(text)
            var out = "Search results for “\(text)” by name (live channels, series, movies, episodes and the guide, in every playlist):\n" + found
            // It may also be a person: films are found through the cast index, which can be partly read.
            let asked = await searchLibrary(text, kind: "")
            if !asked.hasPrefix("Nothing") || asked.contains("cast has only been read") { out += "\n\nRead as a request (cast, genre, language):\n" + asked }
            return out
        default: return nil
        }
    }

    /// What is on screen, said from what the app knows: no model needed.
    func screenAnswer() -> String {
        guard let c = context else { return "Screen sharing is off, so I can only see what you type. Click the eye at the top of this panel to let me see which screen you are on, what is playing and your library counts." }
        var out = "You are on **\(c.screen.isEmpty ? "an unknown screen" : c.screen)**."
        if let q = c.searchText, !q.isEmpty { out += " “\(q)” is typed in the search box." }
        if let o = c.openItem { out += " A title page is open: \(o.split(separator: ".").first.map(String.init) ?? o)." }
        if let n = c.nowPlaying { out += " Playing now: \(n)." } else { out += " Nothing is playing." }
        if !c.library.isEmpty { out += " Your library: \(c.library)." }
        return out
    }

    /// "Play something", "play somwthing", "play something best series": asks for something to watch, not for a title. The library is searched for what was asked (series, movies, best, newest, anything else
    /// said) and the real matches are shown; only then is playing the top one offered, as a button for that exact title. A phrase that matches nothing gets no Play button.
    func discoveryReply(_ text: String) async -> AssistantReply? {
        guard let d = AssistantDiscovery.parse(text), !container.assistantNamesATitle(text) else { return nil }
        step("search_library")
        guard var answer = try? await container.askWhatToWatch(d.query, useAI: false) else { return nil }
        func rating(_ r: AskResult) -> Double { switch r.item { case .movie(let m): Self.tenPointRating(m.rating); case .series(let t): Self.tenPointRating(t.rating) } }
        func year(_ r: AskResult) -> Int { r.item.year ?? 0 }
        var results = answer.results.filter { d.kind == .any || (d.kind == .series) == $0.item.isSeries }
        if d.best { results.sort { rating($0) > rating($1) } } else if d.newest { results.sort { year($0) > year($1) } }
        results = Array(results.prefix(10))
        guard !results.isEmpty else {
            return AssistantReply(say: "I couldn’t find any \(d.label) in your library that match that. Try a language, a genre or a name, or ask me about something specific.", steps: stepsTaken)
        }
        answer.results = results; answer.intent = WatchIntent(); lastAnswer = answer
        let top = results[0].item
        propose(.playItem(id: top.id, isChannel: false, title: top.title), item: top)
        let order = d.best ? ", best rated first" : d.newest ? ", newest first" : ""
        let say = "Here \(results.count == 1 ? "is 1 match" : "are \(results.count) matches") from your library\(order). Tap a poster to open it, or play the top one."
        return AssistantReply(say: say, answer: answer, proposals: proposals, steps: stepsTaken)
    }

    /// A provider's rating on a ten-point scale. Some playlists give a percentage (57 means 5.7) and some give nonsense; neither may outrank a real 9.
    nonisolated static func tenPointRating(_ raw: String?) -> Double {
        guard let raw, let v = Double(raw.trimmingCharacters(in: .whitespaces)), v.isFinite, v > 0 else { return 0 }
        if v <= 10 { return v }
        return v <= 100 ? v / 10 : 0
    }

    /// A name typed on its own (a show, a channel, a film) is answered at once from the app's own search, the way the search box does it, with no model to wait for. Returns nil when it is not a
    /// name, is a person the cast index knows, or finds nothing by name, and then the usual conversation takes over.
    func fastNameReply(_ text: String) async -> AssistantReply? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard (1...5).contains(words.count), words.allSatisfy({ !Self.notAName.contains($0) && !Self.describesAList.contains($0) }), text.count >= 3, AssistantRouter.route(text) == .general else { return nil }
        if !LocalIntent.parse(text, hasPerson: { PeopleIndex(db: container.db).canonicalName(for: $0) }).people.isEmpty { return nil }
        step("search_everything")
        let found = await searchEverything(text)
        guard !found.hasPrefix("Nothing named"), let summary = lastEverything else { return nil }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var say = "Found **\(title)**: \(summary)."
        if lastAnswer?.results.isEmpty == false { say += " Tap a poster to open it." }
        if !proposals.isEmpty { say += " Or play the channel below." }
        var reply = AssistantReply(say: say, answer: Self.cardsFoundByName(lastAnswer), proposals: proposals, steps: stepsTaken)
        reply.instant = true
        return reply
    }

    /// The posters of what was found by name (nothing loosely matched).
    static func cardsFoundByName(_ a: AskAnswer?) -> AskAnswer? {
        guard var a else { return nil }
        a.results = a.results.filter { $0.reasons.contains("Found by name") }
        a.intent = WatchIntent()
        return a
    }

    /// Words that show a phrase is describing a list of titles ("best horror movies", "netflix top movies", "marvel in order", "films like athadu") and not naming one.
    private static let describesAList: Set<String> = ["best", "top", "worst", "popular", "greatest", "movies", "movie", "films", "film", "series", "shows", "serials", "documentaries", "documentary", "thrillers", "thriller", "horror", "comedies", "comedy", "romance",
                                                       "like", "similar", "order", "phases", "collection", "list", "award", "awards", "winning", "winners", "netflix", "prime", "hotstar", "recommend", "based", "true", "story", "stories", "weekend", "tonight", "week", "ranked", "rated"]

    /// Words that make a short phrase a question or a request rather than a name to look up.
    private static let notAName: Set<String> = ["who", "what", "why", "how", "when", "where", "is", "are", "can", "could", "should", "tell", "explain", "show", "give", "find", "recommend", "suggest", "play", "open", "go", "turn", "set", "change", "do", "does", "did", "i", "me", "my", "please", "help", "hi", "hello", "hey", "thanks", "thank", "ok", "okay", "yes", "no"]

    private func presentText(_ f: AssistantFinding) -> String {
        for a in f.actions {
            switch a {
            case "retry": if container.playback.current != nil { propose(.retry) }
            case "engine:mpv", "engine:avPlayer", "engine:auto": propose(.engine(String(a.dropFirst(7))))
            case "sync_guide": propose(.syncGuide)
            case "refresh": propose(.refresh)
            case "open_sources": propose(.command(.init(kind: .go(.settings, library: nil))))
            default: break
            }
        }
        return f.text
    }

    private func sourceSetup(_ type: String) -> String {
        let k = AssistantRouter.sourceKind(in: type) ?? type
        let hits = AppGuide.articles.filter { $0.title.lowercased().contains("adding") && ($0.title.lowercased().contains(k.lowercased()) || $0.keys.contains { k.lowercased().contains($0) }) }
        let base = AppGuide.articles.first { $0.title == "Adding a playlist or source" }
        return (hits.map(\.body) + (base.map { [$0.body] } ?? [])).joined(separator: "\n\n")
    }

    // MARK: the lookups

    private func line(_ i: Int, _ r: AskResult) -> String {
        let it = r.item
        var parts = ["\(i). \(it.title)", it.isSeries ? "series" : "movie"]
        if let g = it.genre, !g.isEmpty { parts.append(g) }
        let langs = LanguageTags.languages(of: it); if !langs.isEmpty { parts.append(langs.sorted().joined(separator: "/")) }
        parts.append(r.watched ? "watched" : "not watched")
        return parts.joined(separator: " · ")
    }

    private func searchLibrary(_ query: String, kind: String) async -> String {
        var q = query
        if kind.lowercased().hasPrefix("movie"), !q.lowercased().contains("movie") { q += " movies" }
        if kind.lowercased().hasPrefix("series"), !q.lowercased().contains("series") { q += " series" }
        guard let a = try? await container.askWhatToWatch(q, useAI: false) else { return "The library could not be searched." }
        lastAnswer = a
        var out = a.results.isEmpty ? "Nothing in the library matches." : "Found in the library (\(a.results.count)):\n" + a.results.prefix(10).enumerated().map { line($0.offset + 1, $0.element) }.joined(separator: "\n")
        if !a.intent.people.isEmpty, a.castCoverage < 0.9, !a.usedTMDB {
            out += "\nNote: the cast has only been read for \(Int(a.castCoverage * 100))% of the library, so films with \(a.intent.people.joined(separator: " and ")) may be missing. If you know that person's films, check them with check_library."
        }
        return out
    }

    /// The whole app's search for a word: live channels, movies, series, episodes and guide entries, in every playlist. The same engine as the search box, so what the person would find there is what the
    /// assistant finds. A run-together or spaced variant ("biggboss", "bigg boss") is tried too.
    private func searchEverything(_ query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return "Give a name to search for." }
        let variants = Self.searchVariants(q)
        var merged: [SearchResultKind: [SearchResult]] = [:], seen = Set<String>()
        for (i, v) in variants.enumerated() {
            guard let r = try? await container.globalSearch.search(v, tab: .all, limit: 12) else { continue }
            let words = v.lowercased().split(separator: " ").map(String.init)
            for (k, rows) in r.byKind {
                for row in rows where seen.insert(row.id).inserted {
                    // A guessed spelling only counts when every one of its words begins a word in the title.
                    if i > 0 {
                        let title = row.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                        guard words.allSatisfy({ w in title.contains { $0.hasPrefix(w) } }) else { continue }
                    }
                    merged[k, default: []].append(row)
                }
            }
        }
        lastEverything = nil
        if merged.values.allSatisfy(\.isEmpty) { return "Nothing named “\(q)” in any playlist: no live channel, movie, series, episode or guide entry." }
        var counts: [String] = []
        for (kind, one, many) in [(SearchResultKind.channel, "live channel", "live channels"), (.series, "series", "series"), (.movie, "movie", "movies"), (.episode, "episode", "episodes"), (.programme, "guide entry", "guide entries")] {
            let n = merged[kind]?.count ?? 0
            if n > 0 { counts.append("\(n) " + (n == 1 ? one : many)) }
        }
        lastEverything = counts.joined(separator: ", ")
        var out: [String] = []
        for kind in [SearchResultKind.channel, .series, .movie, .episode, .programme] {
            let rows = (merged[kind] ?? []).sorted { $0.score > $1.score }
            guard !rows.isEmpty else { continue }
            let list = rows.prefix(8).map { r in r.title + (r.sourceName.map { " [\($0)]" } ?? "") + (r.subtitle.isEmpty ? "" : " — " + r.subtitle) }
            out.append("\(kind.groupTitle) (\(rows.count)): " + list.joined(separator: "; "))
        }
        // Posters for the movies and series found
        var items: [LibraryItem] = []
        for r in ((merged[.series] ?? []) + (merged[.movie] ?? [])).sorted(by: { $0.score > $1.score }).prefix(10) {
            switch r.destination {
            case .movie(let id): if let m = (try? container.catalog.movie(id: id)) ?? nil { items.append(.movie(m)) }
            case .series(let id): if let t = (try? container.catalog.seriesItem(id: id)) ?? nil { items.append(.series(t)) }
            default: break
            }
        }
        if !items.isEmpty {
            var a = lastAnswer ?? AskAnswer(intent: WatchIntent())
            var ids = Set(a.results.map(\.id))
            for it in items where ids.insert(it.id).inserted { a.results.append(AskResult(item: it, reasons: ["Found by name"], score: 1, watched: false)) }
            a.note = "\(a.results.count) found."
            lastAnswer = a
        }
        // Channels can be played: offer the best one
        if let ch = (merged[.channel] ?? []).max(by: { $0.score < $1.score }) { propose(.command(.init(kind: .play(ch.title)))) }
        return out.joined(separator: "\n")
    }

    /// The words as typed, then the ways they might have been run together or split ("biggboss telugu" → "bigg boss telugu"), so a spelling without spaces still finds the title.
    nonisolated static func searchVariants(_ q: String) -> [String] {
        let tokens = q.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return [q] }
        var out = [q]
        func add(_ v: String) { if !out.contains(v) { out.append(v) } }
        if tokens.count > 1 { add(tokens.joined()) }
        for (i, t) in tokens.enumerated() where t.count >= 6 && t.allSatisfy(\.isLetter) {
            for k in 3...(t.count - 3) {
                var parts = tokens
                parts.replaceSubrange(i...i, with: [String(t.prefix(k)), String(t.dropFirst(k))])
                add(parts.joined(separator: " "))
            }
        }
        return Array(out.prefix(14))
    }

    /// "Title (Year)" -> its name and year.
    private func split(_ raw: String) -> (name: String, year: Int?) {
        let year = raw.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression).flatMap { Int(raw[$0]) }
        return (TraktItem.cleanTitle(raw), year)
    }

    private func match(_ raw: String, requireYear: Bool = true) -> LibraryItem? {
        var (name, year) = split(raw)
        if !requireYear { year = nil }
        guard name.count >= 2 else { return nil }
        var q = VODQuery(); q.search = name; q.limit = 25
        if let m = ((try? container.catalog.movies(q)) ?? []).first(where: { TraktMatching.matches(listed: TraktListed(title: name, year: year, isShow: false), title: $0.title, year: $0.releaseYear ?? MetadataNormalizer.year(from: $0.title)) }) { return .movie(m) }
        if let s = ((try? container.catalog.series(q)) ?? []).first(where: { TraktMatching.matches(listed: TraktListed(title: name, year: year, isShow: true), title: $0.title, year: $0.releaseYear) }) { return .series(s) }
        return nil
    }

    /// Matches the AI's candidate titles against the library, one by one, with the app's own search. A candidate may carry alternate spellings after " / ". A match that agrees on the year is firm; one found by
    /// name alone is flagged as possible. The AI's order is kept, and what was not found is listed apart, never shown as if it were here.
    private func checkLibrary(_ titles: [String]) -> String {
        var firm: [LibraryItem] = [], possible: [LibraryItem] = [], missing: [String] = [], seen = Set<String>()
        for raw in titles.prefix(40) {
            let names = raw.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = names.first else { continue }
            let year = split(first).year ?? names.compactMap { split($0).year }.first
            var hit: (LibraryItem, Bool)?
            for n in names { if let m = match(n, requireYear: year != nil) { hit = (m, true); break } }
            if hit == nil, year != nil { for n in names { if let m = match(n, requireYear: false) { hit = (m, false); break } } }
            if let (item, isFirm) = hit { if seen.insert(item.id).inserted { if isFirm { firm.append(item) } else { possible.append(item) } } }
            else { missing.append(first) }
        }
        let have = firm + possible
        var a = AskAnswer(intent: WatchIntent())
        let possibleIDs = Set(possible.map(\.id))
        a.results = have.map { item in AskResult(item: item, reasons: [possibleIDs.contains(item.id) ? "Possible match" : "Suggested by the assistant"], score: 1, watched: false) }
        a.elsewhere = missing
        a.note = have.isEmpty ? "None of those are in your library." : "Found \(have.count) in your library."
        lastAnswer = a
        var out = have.isEmpty ? "None of those titles are in the library." : "In the library (in the order you gave): " + firm.map(\.title).joined(separator: "; ") + "."
        if !possible.isEmpty { out += " Possible matches (found by name only, the year did not agree): " + possible.map(\.title).joined(separator: "; ") + "." }
        if !missing.isEmpty { out += " Not in the library: " + missing.joined(separator: "; ") + "." }
        return out
    }

    private func tvGuide(_ q: String) -> String {
        let c = container
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
        var out: [String] = []
        var cq = ChannelQuery(); cq.search = q; cq.limit = 4
        let channels = (try? c.catalog.channels(cq)) ?? []
        if !channels.isEmpty, let nn = try? c.epgRepo.nowNext(channelIDs: channels.map(\.id), at: Date()) {
            for ch in channels { if let p = nn[ch.id], let now = p.first { out.append("On \(ch.name): now \(now.title)" + (p.count > 1 ? ", next \(p[1].title) at \(f.string(from: p[1].start))" : "")) } }
        }
        let hits = (try? c.epgRepo.searchPrograms(term: q, sourceID: nil, from: Date(), limit: 6)) ?? []
        out += hits.map { "\($0.program.title) on \($0.channelName), \(f.string(from: $0.program.start))" }
        return out.isEmpty ? "Nothing found in the guide for “\(q)”. The guide may not cover it, or it may need a refresh." : out.joined(separator: "\n")
    }

    private func nowPlaying() -> String {
        let p = container.playback
        guard p.current != nil else { return "Nothing is playing." }
        let m = p.metrics
        func t(_ s: TimeInterval) -> String { let x = Int(s); return String(format: "%d:%02d:%02d", x / 3600, (x % 3600) / 60, x % 60) }
        var o = ["Title: \(p.isPrivate ? "Private viewing (hidden)" : p.title)", p.isLive ? "Live TV" : "Video on demand", "State: \(p.state)"]
        if !p.isPrivate, let ch = p.currentChannel, p.isLive, let nn = (try? container.epgRepo.nowNext(channelIDs: [ch.id], at: Date()))?[ch.id], let now = nn.first {
            o.append("Programme now: \(now.title)" + (nn.count > 1 ? ", next: \(nn[1].title)" : ""))
        }
        if !p.isLive, let d = p.duration { o.append("Position \(t(p.position)) of \(t(d))") }
        o.append("Engine: \(p.activeEngine)")
        if m.width > 0 { o.append("Picture: \(m.width)×\(m.height)" + (m.frameRate.map { String(format: " at %.0f fps", $0) } ?? "")) }
        if let v = m.videoCodec { o.append("Video codec: \(v)" + (m.audioCodec.map { ", audio \($0)" } ?? "")) }
        if m.observedBitrate > 0 { o.append(String(format: "Download speed seen: %.1f Mbit/s", m.observedBitrate / 1_000_000)) }
        if m.indicatedBitrate > 0 { o.append(String(format: "Stream bitrate: %.1f Mbit/s", m.indicatedBitrate / 1_000_000)) }
        o.append("Buffered ahead: \(Int(m.bufferedAheadSeconds)) s; stalls: \(m.stallCount) (\(Int(m.totalStallSeconds)) s in total); dropped frames: \(m.droppedFrames)")
        if let s = m.startupSeconds { o.append(String(format: "Took %.1f s to start", s)) }
        o.append("Audio tracks: \(p.audioTracks.count); subtitle tracks: \(p.subtitleTracks.count); volume \(Int(p.volume * 100))%" + (p.isMuted ? " (muted)" : ""))
        if let msg = p.statusMessage, !msg.isEmpty { o.append("Status message: \(msg)") }
        let s = container.settings
        o.append("Settings now: engine \(s.enginePreference.rawValue); buffering \(s.bufferingMode.title); hardware decoding \(s.hardwareDecoding.rawValue); quality \(s.videoQuality.rawValue)")
        return o.joined(separator: "\n")
    }

    private func stats(_ period: String) -> String {
        let since: Date? = period == "week" ? Date().addingTimeInterval(-7 * 86400) : period == "month" ? Date().addingTimeInterval(-30 * 86400) : nil
        guard let s = try? StatisticsService(db: container.db, catalog: container.catalog).compute(since: since), !s.isEmpty else { return "No viewing recorded for that period." }
        func h(_ t: TimeInterval) -> String { String(format: "%.1f hours", t / 3600) }
        var out = "Watched \(h(s.totalSeconds)) in \(s.sessions) sessions (live \(h(s.liveSeconds)), movies \(h(s.movieSeconds)), series \(h(s.seriesSeconds)))."
        if let c = s.topChannels.first { out += " Most watched channel: \(c.title)." }
        if let m = s.topMovies.first { out += " Top movie: \(m.title)." }
        if let t = s.topSeries.first { out += " Top series: \(t.title)." }
        return out
    }

    // MARK: with no AI chosen

    /// The assistant's best effort from the words alone: commands, settings changes and questions, how-tos, library searches. It says so when an AI would do better.
    func localReply(_ text: String) async -> AssistantReply {
        let lower = text.lowercased()
        if let offers = container.assistantCommandProposals(text) { proposals.append(contentsOf: offers); return reply("I can do that:") }
        if let found = await discoveryReply(text) { return found }
        let intent = AssistantRouter.route(text)
        if intent == .unsupported {
            return reply("StreamSetu is a player: it does not provide channels, playlists or IPTV subscriptions, and I can’t recommend where to get them. You add sources you are entitled to use (Settings → Library → Manage), and I can help with that, with finding things in them, or with playback problems.")
        }
        if let evidence = await preload(intent, text: text) { return reply(evidence) }
        // "turn on subtitles by default", "disable reminders"
        if let m = text.range(of: #"(?i)\b(turn|switch|set|enable|disable)\b"#, options: .regularExpression) {
            let verb = String(text[m]).lowercased()
            let want: String? = verb == "disable" ? "off" : verb == "enable" ? "on" : lower.contains(" off") ? "off" : lower.contains(" on") ? "on" : nil
            if let want, let e = AppSettingsCatalog.search(text, limit: 3).first(where: { $0.changeable && $0.kind == .toggle }) {
                propose(.setting(id: e.id, value: want))
                return reply("\(e.title): \(e.detail) It is \(e.read?(container.settings) ?? "?") now. Tap to turn it \(want).")
            }
        }
        let question = lower.hasPrefix("how") || lower.hasPrefix("what") || lower.hasPrefix("where") || lower.hasPrefix("why") || lower.hasPrefix("can i") || lower.contains("?") || lower.contains("setting")
        if question {
            let es = AppSettingsCatalog.search(text, limit: 2)
            let gs = AppGuide.search(text, limit: 1)
            if !es.isEmpty || !gs.isEmpty {
                var parts = es.map { "\($0.title) — \($0.detail) Now: \($0.read?(container.settings) ?? "—"). Find it at \($0.path)." }
                parts += gs.map(\.body)
                return reply(parts.joined(separator: "\n\n") + "\n\n(Add an AI in Settings → Integrations for open conversation.)")
            }
        }
        // Anything else: a name or a request. Search everything for it, and read it as a request too.
        let everywhere = await searchEverything(text)
        let asked = await searchLibrary(text, kind: "")
        let hadEverywhere = !everywhere.hasPrefix("Nothing named")
        let hadRequest = lastAnswer?.results.isEmpty == false && !asked.hasPrefix("Nothing")
        var say = hadEverywhere ? "Here is what I found for “\(text)”:\n\n" + everywhere : hadRequest ? (lastAnswer?.note ?? "Here is what I found.") : "I did not find anything for that in any playlist. With an AI connected (Settings → Integrations) I can answer open questions too."
        if hadEverywhere && lastAnswer?.results.isEmpty == false { say += "\n\nPosters are below." }
        var r = reply(say)
        r.answer = lastAnswer
        return r
    }

    private func reply(_ say: String) -> AssistantReply { AssistantReply(say: say, answer: lastAnswer, proposals: proposals, steps: stepsTaken) }
}
