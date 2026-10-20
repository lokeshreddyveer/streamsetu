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
}
