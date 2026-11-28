import Foundation

/// Corrections to app entries whose text was stale, thin or wrong on a platform (see docs in ~/Documents/dev/setu-knowledge-audit-app.md, sections 3a, 3c and 3e). Each one is laid over the entry with the same id after
/// the declarations are merged (`AtlasRefine`), so the file that declares the entry does not change. Every statement below was checked against the screen code the audit names.
enum AppRefinements {
    private static func r(title: String? = nil, _ summary: String? = nil, detail: String? = nil, path: [String]? = nil, aliases: [String] = [], reach: AtlasReach? = nil, platforms: AtlasPlatforms? = nil,
                          related: [String] = [], shortcut: String? = nil, safety: AtlasSafety? = nil) -> AtlasRefinement {
        AtlasRefine.r(title: title, summary, detail: detail, path: path, aliases: aliases, reach: reach, platforms: platforms, related: related, shortcut: shortcut, safety: safety)
    }

    static let table: [String: AtlasRefinement] = whatsNew.merging(stale) { a, _ in a }.merging(thin) { a, _ in a }.merging(platforms) { a, _ in a }

    // MARK: what's new

    static let whatsNew: [String: AtlasRefinement] = [
        "meta.whatsNew": r("What's New appears once after an update, when the opening ends. The latest release is Mac 2.18.0 and iPhone and iPad 1.4 (build 79), from 23 November 2026: streaming services inside the Mac app, title pages, genre shelves, stars on every tile, better artwork matching, smoother scrolling, and Setu on iPhone and iPad. About shows your version.",
                           related: ["meta.whatsNew.2026.11.23", "meta.whatsNew.2026.11.23.mac", "meta.whatsNew.2026.11.23.ios", "meta.whatsNew.music"]),
    ]

    // MARK: stale

    static let stale: [String: AtlasRefinement] = [
        "setting.guide.enrichmentEnabled": r(title: "Use the public channel database", "The same switch as Fill missing logos, genres and countries in Settings, Library, Guide sources: it turns the daily download of the public channel list on or off.",
                                             path: ["Settings", "Library", "Guide sources"], related: ["setting.guide.publicDatabase"], safety: .read),
        "setting.guide.reminderLeadMinutes": r(title: "Remind me before (guide reminders)", "A menu in the TV Guide's reminders list that sets how many minutes before a programme its reminder appears: 1, 5, 10 or 15. It is not in Settings.",
                                               path: ["TV Guide", "Reminders"], safety: .read),
        "setting.storage.guideBannerDismissed": r(title: "Guide warning dismissed", "An internal flag that remembers you closed the TV Guide's freshness banner. It is not a setting you change.", path: ["TV Guide"], safety: .read),
        "setting.guide.sources": r(safety: .read), "setting.guide.addXMLTV": r(safety: .read), "setting.guide.publicDatabase": r(safety: .read), "setting.guide.enrichLogos": r(safety: .read),
        "screen.settings.backup": r("The Backup page of Settings on iPhone and iPad. On the Mac, backup is in Settings, Library, Backup.", platforms: [.iPhone, .iPad]),
        "screen.settings.storage": r("The Storage page of Settings on iPhone and iPad. On the Mac, storage is in Settings, Library, Storage.", platforms: [.iPhone, .iPad]),
        "screen.person": r("An actor or director: a short biography and their films and series. A switch shows In your library only or All films. The full filmography uses the details service, which works out of the box with a key built into the app; your own key is optional.",
                           related: ["setting.tmdb"]),
        "recipe.fixWrongArtwork": r("Posters, summaries and ratings come from your playlist first and then, for what is missing, from the details and artwork services. The details service works out of the box with a key built into the app; a key of your own is optional. If a poster is wrong, press Match now to match again.",
                                    related: ["diag.artwork"]),
        "diag.artwork": r("Posters, summaries, years and ratings your playlist lacks are matched in the background, on Wi-Fi, from the details service and three more artwork sources (fanart.tv, TheTVDB and TVmaze), using the title and year. A wrong poster is usually a wrong match on a similar title.",
                          detail: "Settings, Library, Artwork and details: check that matching is on, press Match now, and allow mobile data or hotspots if you are not on Wi-Fi. Each source can be switched off there. No key is needed, because one is built into the app; your own TMDB key is optional. Clear artwork cache (Settings, Advanced, Reset) makes posters download again.",
                          aliases: ["fanart", "thetvdb", "tvmaze", "artwork sources"]),
        "diag.castSearch": r(detail: "Settings, Library, Cast and directors shows how many movies have been read. Read Cast Now speeds it up, four at a time. An actor's full filmography on their person page comes from the details service, which works without any key from you.",
                             related: ["screen.person"]),
        "meta.privacySetu": r("Answers from the app's own knowledge stay on this device. If you connect an AI service, it is sent the words you type and the topics Setu looked up for them, plus library titles when a lookup returns them. Never logins, playlist addresses or tokens.",
                              detail: "The eye button controls the extra context: on, Setu is also told the screen name, what is playing, the open title, the search text, library counts and a short summary of what you usually watch (top genres and languages, learned on this device). Watch Privately sessions are reported only as Private viewing. A search, watch-stats or library lookup can return titles from your library to the AI. Misses are counted on this device only.",
                              aliases: ["does setu send my watch history to the ai", "what does the ai see", "is my history sent to setu", "assistant privacy"], related: ["control.setu.shareScreen", "control.setu.modelMenu"]),
        "screen.assistant": r("The Setu panel opens from the Setu button at the top right (Mac) or the chat button at the bottom right (iPhone and iPad). Ask how something works, where a setting is, why something failed, or for a change; every change is a button you confirm. Its header has an eye (share my screen), a new chat arrow and a close button, and a pill that shows the engine. It is hidden in kids profiles.",
                             detail: "With no AI connected Setu still answers from what is in the app. Command Return sends; Escape closes. If nothing matches, it names the closest topics and offers to open the nearest screen.",
                             aliases: ["what is setu", "setu panel", "how do i open setu", "ask the assistant"], related: ["control.setu.shareScreen", "control.setu.newChat", "control.setu.modelMenu", "meta.setuCanChange", "meta.setuTools", "control.search.topBar"]),
        "meta.canDoHere": r("Ask me where something is, how to do it, what a setting does, why something is not working, or what any screen, shortcut or error message means. I answer from what is in the app, so I work with no AI connected, and if I do not know I say what is closest and offer to open it.",
                            related: ["meta.setuTools", "meta.setuCanChange", "control.search.topBar"]),
        "screen.podcasts": r("On the Mac, Podcasts is its own destination (command 7, or Podcasts in the top bar) with Discover, Following, Recently Played and Up Next. The older Podcasts page in the Files and Servers window finds shows in Apple's public podcast directory, follows them and plays episodes; your place in each episode is remembered.",
                             related: ["screen.destination.podcasts"]),
        "setting.profiles": r("Gives each person their own favourites, collections, watch history and resume points; everyone shares the same playlists. Up to four profiles per device. A profile can ask for a 4 to 8 digit PIN to open it, and a kids profile hides locked folders, needs its PIN to leave, hides Setu, and can have Limits (time each day, no watching at night). It is in Settings, Library, Profiles.",
                              path: ["Settings", "Library", "Profiles"],
                              aliases: ["that pin is not right", "could not switch", "check the name it must be new and the pin 4 to 8 digits", "profile pin wrong"], related: ["setting.viewingLimits", "control.profiles.add", "control.profiles.remove"]),
    ]

    // MARK: thin

    static let thin: [String: AtlasRefinement] = [
        "screen.recordings": r("Live channels you recorded while watching them, plus recordings you scheduled from the TV Guide, one-off or repeating weekly (a weekly repeat is Mac only and the app must be open at the time). Files stay on this Mac, out of backups, and the list is in Settings, Library, Recordings. Recording is not available on iPhone and iPad.",
                               platforms: .mac, related: ["setting.scheduledRecordings", "recipe.record"]),
        "screen.title.movie": r("The page of one movie: play or resume, Start Over, favourite, watch later, download, share, a trailer, a More menu (Mark as Watched, Watch Privately, Add to Collection, In folder), cast, a franchise timeline where there is one, quality and sound badges (4K, HDR, Dolby Vision, Atmos, 5.1), a chooser when there are several versions, and the same film in other languages.",
                                related: ["recipe.watchPrivately", "meta.supportedFormats"]),
        "screen.title.series": r("The page of one series: seasons and episodes, play and next episode, favourite, watch later, share, a trailer, Add to Collection and Watch Privately in the More menu, cast, similar titles, quality and sound badges and other versions or languages.", related: ["recipe.watchPrivately"]),
        "screen.search": r("The top search box finds channels, movies, series, episodes and guide programmes from every playlist as you type, and also takes sentences such as telugu movies 2024 unwatched. Type a question or request and the first row becomes Ask Setu; press Return to ask. Filter by type, press Show more for more of a type, and use Command K to focus the box.",
                           related: ["control.search.topBar", "shortcut.search.askSetu"]),
        "screen.searchResults": r("The results under the top search box: Ask Setu first when the text reads as a question, then commands you can run (go to live tv), settings and screens that match, a smart picks card and the library results with a type filter and Show more. Arrow keys move, Return opens, Escape clears.",
                                  related: ["control.search.askSetuRow", "control.search.topBar"]),
        "control.statistics.area": r("Statistics for 7 days, 30 days or all time, with a Reset button and the Your week card. The switch picks the period the page reports on.", related: ["control.statistics.weeklyDigest"]),
        "guide.signInAndLoginProblems": r("A login problem is shown as a number from your provider: 401 means the login was rejected (wrong user name or password), 403 means the server refused it (often an ended subscription or a blocked device) and 429 means too many requests or too many devices at once. Fix it with Edit Login, or Change Login or Address, on the playlist in Settings, Library, Manage, Playlists, then refresh.",
                                          detail: "Check with your provider if the details are right. Backup and restore never carry passwords, so a restored playlist always asks again.", related: ["diag.source", "diag.backupRestore"]),
        "guide.playbackProblems": r("Five quick fixes for a stream that stutters, freezes or will not start: another engine, hardware decoding, the buffering mode, a refresh, and checking the source. A stream that stalls three times shows a hint with quick fixes, and a failed stream shows an error card with its own buttons; ask me why is this channel buffering to read the stream's numbers.",
                                    related: ["control.player.bufferingHint", "recipe.fixBuffering"]),
    ]

    // MARK: settings that exist only on the Mac

    /// Settings whose controls are not in the iPhone and iPad apps (the audit searched that target for each word).
    static let platforms: [String: AtlasRefinement] = {
        var t: [String: AtlasRefinement] = [:]
        for id in ["setting.toneMapping", "setting.deinterlace", "setting.renderingProfile", "setting.stereoDownmix", "setting.density", "setting.clickBehavior", "setting.sidebarLaunch", "setting.liveRewind", "setting.guideHoursVisible", "setting.recordings"] {
            t[id] = r(platforms: .mac)
        }
        t["guide.keyboard"] = r(platforms: [.mac, .iPad])
        return t
    }()
}
