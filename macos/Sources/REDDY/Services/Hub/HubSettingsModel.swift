import Foundation
import Observation

/// What Settings > Artwork and Details shows for fanart.tv, TheTVDB and TVmaze, for the Mac and iOS screens alike. TMDB keeps its own group (ArtworkSettingsModel).
/// This is the only place the services are named, with the credits (About and Settings).
@MainActor @Observable final class HubSettingsModel {
    struct Card: Identifiable, Equatable {
        let source: HubSource
        let title: String
        let help: String
        let keyLabel: String?
        var id: HubSource { source }
    }
    nonisolated static let cards: [Card] = [
        Card(source: .fanart, title: "fanart.tv", help: "Extra logos, backgrounds and posters. Asked only for a title you open or see, once per title. Your own free personal key is optional: it is sent in addition to the app's key and new images from the community reach you in 2 days instead of 7.", keyLabel: "Your fanart.tv personal key (optional)"),
        Card(source: .tvdb, title: "TheTVDB", help: "Episode details and artwork for series. On by default, using the app's built-in key unless you add your own TheTVDB subscriber key (and PIN). You can switch it off here. Its credit is under Credits in Settings.", keyLabel: "Your TheTVDB subscriber key"),
        Card(source: .tvmaze, title: "TVmaze", help: "Next-episode dates, seasons and schedules for series. Needs no key and sends only a show id.", keyLabel: nil),
    ]
    /// The sentence Settings shows about retention, built from the numbers in `Retention`.
    nonisolated static var keepNote: String { "Saved details are kept for at most \(Retention.maxKeepDays) days (\(Int(Retention.tvdbKeep / Retention.day)) days for TheTVDB) and removed when you switch a source off." }

    var enabled: [HubSource: Bool] = [:]
    var hasKey: [HubSource: Bool] = [:]
    var status: [HubSource: String] = [:]
    var message: [HubSource: String] = [:]
    var failed: [HubSource: Bool] = [:]
    var testing: Set<HubSource> = []
    var hasPin = false

    private let accessFor: (HubSource) -> HubAccess
    private let fetch: HubFetch
    private let store: HubStore?
    init(store: HubStore?, fetch: @escaping HubFetch, access: @escaping (HubSource) -> HubAccess = { HubAccess.standard($0) }) {
        self.store = store; self.fetch = fetch; accessFor = access; refresh()
    }

    func refresh() {
        for c in Self.cards {
            let a = accessFor(c.source)
            enabled[c.source] = a.enabled; hasKey[c.source] = a.ownKey != nil; status[c.source] = a.statusLine
        }
        hasPin = accessFor(.tvdb).pin != nil
    }
    func setEnabled(_ s: HubSource, _ on: Bool) {
        var a = accessFor(s); a.enabled = on
        if !on { store?.purge(source: s) }
        message[s] = nil; refresh()
    }
    func saveKey(_ s: HubSource, _ key: String, pin: String? = nil) {
        let a = accessFor(s); a.setOwnKey(key)
        if s == .tvdb, let pin, !pin.trimmingCharacters(in: .whitespaces).isEmpty { a.secrets.set(pin.trimmingCharacters(in: .whitespaces), for: HubAccess.tvdbPinAccount) }
        if s == .tvdb { a.secrets.set(nil, for: TVDBSession.tokenAccount) }            // a new key logs in afresh
        say(s, "Key saved."); refresh()
    }
    func removeKey(_ s: HubSource) {
        let a = accessFor(s); a.setOwnKey(nil)
        if s == .tvdb { a.secrets.set(nil, for: HubAccess.tvdbPinAccount); a.secrets.set(nil, for: TVDBSession.tokenAccount) }
        say(s, "Your key was removed."); refresh()
    }

    /// One small request: shows only OK, key refused, or no answer.
    func test(_ s: HubSource) {
        testing.insert(s); say(s, "Checking…")
        let a = accessFor(s), fetch = fetch
        Task {
            let r = await Self.check(s, access: a, fetch: fetch)
            say(s, r.text, failed: !r.ok); testing.remove(s); refresh()
        }
    }
    nonisolated static func check(_ s: HubSource, access a: HubAccess, fetch: @escaping HubFetch) async -> (ok: Bool, text: String) {
        do {
            switch s {
            case .fanart:
                guard let k = FanartKeys.resolve(a), let r = FanartProvider.request(kind: .movie, id: "603", keys: k) else { return (false, "No key available.") }
                _ = try await fetch(r)
            case .tvdb:
                guard a.enabled || a.ownKey != nil else { return (false, "Switched off.") }
                _ = try await TVDBSession(access: a, fetch: fetch).currentToken(forceRefresh: true)
            case .tvmaze:
                guard let u = URL(string: "https://api.tvmaze.com/shows/1") else { return (false, "No answer, try again.") }
                _ = try await fetch(URLRequest(url: u, timeoutInterval: 20))
            default: return (false, "No answer, try again.")
            }
            return (true, "Accepted. This source is working.")
        } catch let e as NetworkError {
            if case .http(let st, _) = e { if st == 401 || st == 403 { return (false, "The key was refused. Check that you copied it whole.") }; if st == 429 { return (false, "The service asked us to slow down. Try again in a few minutes.") } }
            return (false, "No answer, try again.")
        } catch { return (false, "No answer, try again.") }
    }
    private func say(_ s: HubSource, _ m: String, failed f: Bool = false) { message[s] = m; failed[s] = f }
}

/// Credits for all services, shown in Settings and About. The TheTVDB footer is the one place a service is named elsewhere (see HubAttribution).
enum ServiceCredits {
    struct Credit: Identifiable { let id: String; let text: String; let linkTitle: String; let url: URL }
    /// Every service and library the app credits, in one list (Settings > Credits). TMDB's logo and notice are drawn by `TMDBAttribution`, which then lists the rest.
    static let all: [Credit] = {
        var list: [Credit] = [
            Credit(id: "tmdb", text: MetadataMatchService.attribution, linkTitle: "themoviedb.org", url: URL(string: "https://www.themoviedb.org")!),
            Credit(id: "tvdb", text: "Metadata provided by TheTVDB.com. Please consider adding missing information or subscribing.", linkTitle: "thetvdb.com", url: URL(string: HubAttribution.tvdbLink)!),
            Credit(id: "fanart", text: HubAttribution.fanartCredit, linkTitle: "fanart.tv", url: URL(string: HubAttribution.fanartLink)!),
            Credit(id: "tvmaze", text: HubAttribution.tvmazeCredit, linkTitle: "tvmaze.com", url: URL(string: HubAttribution.tvmazeLink)!),
            Credit(id: "iptvorg", text: "Channel logos and genres from the iptv-org public channel database", linkTitle: "github.com/iptv-org", url: URL(string: "https://github.com/iptv-org")!),
            Credit(id: "wikidata", text: "Aliases: Wikidata, CC0", linkTitle: "wikidata.org", url: URL(string: "https://www.wikidata.org")!),
            Credit(id: "opensubtitles", text: "Subtitles from OpenSubtitles", linkTitle: "opensubtitles.com", url: URL(string: "https://www.opensubtitles.com")!),
            Credit(id: "wikipedia", text: "Wikipedia text is used under CC BY-SA, with a link to the article", linkTitle: "wikipedia.org", url: URL(string: "https://www.wikipedia.org")!),
        ]
        list.append(Credit(id: "sparkle", text: "App updates on Mac use Sparkle (MIT licence)", linkTitle: "sparkle-project.org", url: URL(string: "https://sparkle-project.org")!))
        list.append(Credit(id: "sponsorblock", text: "Sponsor-segment times for YouTube (Mac, only if you turn on sponsor skipping) come from SponsorBlock, by Ajay Ramachandran and contributors, licensed CC BY-NC-SA 4.0. Only the first 4 characters of a hash of the video id are sent.", linkTitle: "sponsor.ajay.app", url: URL(string: "https://sponsor.ajay.app")!))
        list.append(Credit(id: "mpv", text: "Playback uses mpv and FFmpeg (open-source licences), packaged by MPVKit", linkTitle: "mpv.io", url: URL(string: "https://mpv.io")!))
        return list
    }()
    static let privacy = "These extra sources are only sent a numeric id (never a title, your history or anything about this device), and only for titles you open or see; titles in locked or hidden folders are never sent. The images come from their own servers, which see your network address like any website."
}
