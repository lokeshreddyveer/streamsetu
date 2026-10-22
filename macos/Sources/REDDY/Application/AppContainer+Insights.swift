import Foundation

/// The numbers behind the weekly digest and the privacy report.
extension AppContainer {
    private func count(_ sql: String) -> Int { ((try? db.read { try $0.queryOne(sql) { $0.int(0) } }) ?? nil) ?? 0 }

    func privacyState() -> PrivacyReport.State {
        PrivacyReport.State(diagnosticsOn: DiagnosticsUploader.shared.isEnabled,
                            hasTMDBKey: metadata.hasKey,
                            hasOpenSubtitles: !OnlineSubtitles.Account.load(from: credentials).key.isEmpty,
                            iCloudSync: settings.iCloudSync, lanSync: settings.lanSync,
                            profileCount: profiles.profiles.count,
                            historyCount: count("SELECT COUNT(*) FROM watch_history"),
                            favoriteCount: count("SELECT COUNT(*) FROM favorites"),
                            searchCount: count("SELECT COUNT(*) FROM search_history"),
                            sessionCount: count("SELECT COUNT(*) FROM playback_sessions"),
                            playlistCount: ((try? catalog.sources()) ?? []).count)
    }

    func weeklyDigest(now: Date = Date()) -> WeeklyDigest {
        let week = (try? statistics.compute(since: now.addingTimeInterval(-7 * 86400), now: now)) ?? ViewingStatistics()
        let fortnight = (try? statistics.compute(since: now.addingTimeInterval(-14 * 86400), now: now))?.totalSeconds ?? week.totalSeconds
        return WeeklyDigest.make(thisWeek: week, last7Days: max(0, fortnight - week.totalSeconds), seriesWithNewEpisodes: newEpisodes.seriesIDs().count,
                                 subscriptionNotes: accounts.warnings(now: now).map { "\($0.sourceName): \($0.text)" })
    }

    /// Rewrites the Sunday notification from the latest numbers; called when the app starts and when the switch changes.
    func refreshWeeklyDigest() {
        let on = WeeklyDigestSchedule.isEnabled(settings.defaultsStore)
        let digest = weeklyDigest()
        Task { await WeeklyDigestSchedule.reschedule(digest: digest, enabled: on) }
    }

    /// What the person usually watches at their usual time: its name and how to start it. Nil until there is a habit.
    func usualEvening(now: Date = Date()) -> (pick: UsualPick, title: String, play: @MainActor () -> Void)? {
        let rows = (try? statistics.sessions(since: now.addingTimeInterval(-UsualEvening.lookBack))) ?? []
        guard let pick = UsualEvening.pick(sessions: rows.map { ($0.itemID, $0.start) }, now: now) else { return nil }
        if let c = (try? catalog.channel(id: pick.itemID)) ?? nil { return (pick, c.name, { [playback] in playback.play(channel: c) }) }
        if let m = (try? catalog.movie(id: pick.itemID)) ?? nil { return (pick, m.title, { [playback] in playback.play(movie: m) }) }
        if let e = (try? catalog.episode(id: pick.itemID)) ?? nil, let s = (try? catalog.seriesItem(id: e.seriesID)) ?? nil {
            return (pick, s.title, { [playback, history] in
                if let next = (try? history.upNext(limit: 20, sourceID: nil))?.first(where: { $0.series.id == s.id }) { playback.play(episode: next.episode, series: next.series) }
                else { playback.play(episode: e, series: s) }
            })
        }
        return nil
    }

    /// Rewrites the reminder for the usual time from the latest habit; called when the app starts and when the switch changes.
    func refreshUsualEvening() {
        let on = settings.defaultsStore.bool(forKey: UsualEvening.enabledKey)
        let usual = usualEvening()
        Task { await UsualEvening.reschedule(pick: usual?.pick, title: usual?.title, enabled: on) }
    }

    /// Plays on this device what another device is playing. The resume point comes from the synced progress.
    func takeOver(_ entry: NowPlayingBoard.Entry) {
        guard entry.key.count == 3, let id = lanAdapter.localItemID(entry.key) else { return }
        switch entry.key[1] {
        case "channel": if let c = (try? catalog.channel(id: id)) ?? nil { playback.play(channel: c) }
        case "movie": if let m = (try? catalog.movie(id: id)) ?? nil { playback.play(movie: m, resume: true) }
        case "episode": if let e = (try? catalog.episode(id: id)) ?? nil, let s = (try? catalog.seriesItem(id: e.seriesID)) ?? nil { playback.play(episode: e, series: s, resume: true) }
        default: break
        }
    }

    /// Adds the titles of the Trakt watchlist that are in the library to Watch Later. Returns how many were added, how many were found in the library, and how many Trakt listed.
    func importTraktWatchlist() async throws -> (added: Int, found: Int, total: Int) {
        let listed = try await trakt.watchlist()
        let catalog = self.catalog
        let found: [(id: String, kind: ContentKind)] = await Task.detached {
            var out: [(String, ContentKind)] = [], seen = Set<String>()
            for l in listed {
                let word = TraktItem.cleanTitle(l.title)
                guard word.count >= 2 else { continue }
                var q = VODQuery(); q.search = word; q.limit = 25
                if l.isShow {
                    if let s = ((try? catalog.series(q)) ?? []).first(where: { TraktMatching.matches(listed: l, title: $0.title, year: $0.releaseYear) }), seen.insert(s.id).inserted { out.append((s.id, .series)) }
                } else if let m = ((try? catalog.movies(q)) ?? []).first(where: { TraktMatching.matches(listed: l, title: $0.title, year: $0.releaseYear ?? MetadataNormalizer.year(from: $0.title)) }), seen.insert(m.id).inserted { out.append((m.id, .movie)) }
            }
            return out
        }.value
        let already = (try? db.read { try $0.query("SELECT item_id FROM collection_items WHERE collection_id = ?", [AppState.watchLaterListID]) { $0.string(0) } }) ?? []
        var added = 0
        if !found.isEmpty { try? db.write { c in try c.execute("INSERT OR IGNORE INTO collections(id, name, created_at) VALUES(?,?,?)", [AppState.watchLaterListID, "Watch Later", Date()]) } }
        for f in found where !already.contains(f.id) { if (try? favoritesRepo.add(itemID: f.id, kind: f.kind, toCollection: AppState.watchLaterListID)) != nil { added += 1 } }
        onCloudChange?(SyncApplyResult(applied: added, tables: ["collections"]))
        return (added, found.count, listed.count)
    }

    /// Resolves a pasted link or magnet through the person's debrid account and plays it.
    func playDebrid(_ input: String) async throws {
        let account = debrid.load()
        let result = try await DebridClient(service: account.service, token: account.token).resolve(input)
        playback.play(file: result.url, title: result.name)
        playback.isExpanded = true
    }

    /// Whether the chosen AI can be asked from the search box (one is chosen, and this is not a kids profile).
    var aiAvailable: Bool { !parental.kidsMode && ai.load().isReady }

    /// Whether what was typed reads like a request (a person, a language, a mood…) and not just a title, so the search can offer smart picks. Read on the device; nothing is sent.
    func looksLikeARequest(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6, t.contains(" "), !parental.kidsMode else { return false }
        let i = LocalIntent.parse(t) { PeopleIndex(db: db).canonicalName(for: $0) }
        if !i.guessedPeople.isEmpty, !metadata.hasKey, !ai.load().isReady { var j = i; j.people = []; j.guessedPeople = []; return !j.isEmpty }          // a name the index does not know can only be checked with TMDB or an AI
        return !i.people.isEmpty || !i.genres.isEmpty || !i.languages.isEmpty || i.year != nil || i.decade != nil || i.maxMinutes != nil || i.minRating != nil || !i.excludeGenres.isEmpty || i.surprise || (i.keywords.count >= 2 && t.split(separator: " ").count >= 4)
    }

    var ai: AIStore { AIStore(defaults: settings.defaultsStore, credentials: credentials) }

    /// Understands the request (with the chosen AI when there is one, and always with the library's own cast index), then finds the answers in the library on this device.
    /// The AI never supplies titles to show: it reads the words, and (with no TMDB key) says what a person is known for, which is only used to look for those titles in the library.
    func askWhatToWatch(_ request: String, previous: WatchIntent? = nil, useAI: Bool = true) async throws -> AskAnswer {
        guard !parental.kidsMode else { throw AIError.unavailable("The AI is not available in a kids profile.") }
        let index = PeopleIndex(db: db)
        let local = LocalIntent.parse(request) { words in index.canonicalName(for: words) }
        var intent = local
        var aiNote: String?
        let config = useAI ? ai.load() : AIConfig(provider: .apple)
        if useAI, config.isReady {
            do {
                let answer = try await AIClient(config: config).ask(system: IntentAdvisor.system, prompt: IntentAdvisor.prompt(request, previous: previous))
                if var fromAI = IntentAdvisor.parse(answer) {
                    // A name the AI gave is trusted only once it is a name the cast index knows (or TMDB resolves, below); otherwise the words are kept as a title search.
                    fromAI.people = fromAI.people.compactMap { index.canonicalName(for: $0.lowercased()) ?? ((metadata.hasKey || config.isReady) ? $0 : nil) }
                    // An AI that names a person must not also invent a language or genre the request never mentioned (small on-device models do).
                    if !fromAI.people.isEmpty || !local.people.isEmpty {
                        let said = request.lowercased()
                        fromAI.languages = fromAI.languages.filter { said.contains($0.lowercased()) }
                        if local.genres.isEmpty { fromAI.genres = [] }
                    }
                    intent = local.merged(with: fromAI)
                }
            } catch let e as AIError where config.provider != .apple { aiNote = e.localizedDescription }
            catch { aiNote = nil }
        }
        if let previous { intent = previous.refined(by: intent) }
        var lib = AskLibrary(catalog: catalog, people: index, history: historyRepo)
        lib.request = request
        lib.taste = await Task.detached { [catalog, historyRepo] in TasteProfile.learn(history: historyRepo, catalog: catalog, people: index) }.value
        if useAI, config.isReady, settings.defaultsStore.object(forKey: "askai.judge") as? Bool ?? true {
            lib.judge = { system, prompt in try? await AIClient(config: config).ask(system: system, prompt: prompt) }
        }
        if metadata.hasKey { let m = metadata; lib.filmography = { name in try? await m.filmography(of: name) } }
        else if useAI, config.isReady {
            lib.filmography = { name in
                guard let answer = try? await AIClient(config: config).ask(system: KnownForAdvisor.system, prompt: KnownForAdvisor.prompt(name)) else { return nil }
                return KnownForAdvisor.parse(answer, name: name)
            }
        }
        var out = await lib.answer(intent)
        if let aiNote { out.note = "The AI could not be reached (" + aiNote + "). Showing what the library itself found. " + out.note }
        return out
    }
}
