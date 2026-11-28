import Foundation

/// What Setu must know about the app beyond single controls: kids limits and profiles, Home and Statistics extras, links and widgets, what StreamSetu is, which devices and formats it supports, and the fixes
/// for the messages people actually see. Every entry was written from the screen code named in docs/setu-knowledge-audit-app (ProfileViews, InsightsViews, HomeScreen, ServiceFailureCopy and the others).
enum AtlasAppKnowledge {
    private static func e(_ kind: AtlasKind, _ id: String, _ title: String, _ summary: String, _ path: [String], aliases: [String] = [], detail: String? = nil, platforms: AtlasPlatforms = .all,
                          shortcut: String? = nil, related: [String] = [], reach: AtlasReach = .none, safety: AtlasSafety = .read, guideOnly: Bool = false) -> AtlasEntry {
        .make(id, kind, title, summary, path: path, reach: reach, aliases: aliases, detail: detail, platforms: platforms, shortcut: shortcut, related: related, safety: safety, guideOnly: guideOnly, reviewed: true)
    }

    static let all: [AtlasEntry] = profiles + home + about + fixes

    // MARK: profiles and kids

    static let profiles: [AtlasEntry] = [
        e(.setting, "setting.viewingLimits", "Viewing limits for a kids profile", "In a kids profile's row, Limits sets Time each day (No limit, 30, 45, 60, 90 minutes, 2 hours or 3 hours) and No watching at night (From and Until; it may cross midnight). Time counts only while something plays. When it runs out playback stops and a full-screen note appears; the profile's PIN adds 30 more minutes for the day (Ask a parent).",
          ["Settings", "Library", "Profiles", "Limits"], aliases: ["screen time for kids", "limit how long my child watches", "bedtime for kids", "no watching at night", "time each day", "enough for today", "daily limit", "kids time limit", "how do i limit how long my kid watches"],
          detail: "Only reachable from outside the kids profile and kept on this device. Setu explains it but never changes it.", related: ["setting.profiles", "diag.viewingBlock", "recipe.kidsProfile"], reach: .settingsPage("Library"), safety: .never, guideOnly: true),
        e(.control, "control.profiles.add", "Add a profile, PIN to open it, Kids profile", "Add a profile with a name, the Kids profile switch and, for a grown-up profile, Ask for a PIN to open this profile (4 to 8 digits). Each profile keeps its own favourites, collections, watch history and resume points; playlists are shared. Up to four profiles per device.",
          ["Settings", "Library", "Profiles", "Add"], aliases: ["add a profile", "pin to open a profile", "how many profiles", "4 profiles", "new profile", "make a profile for my wife"], related: ["setting.profiles", "recipe.kidsProfile"], reach: .settingsPage("Library"), safety: .never, guideOnly: true),
        e(.control, "control.profiles.remove", "Remove a profile", "Removing a profile deletes that profile's favourites, collections, watch history and resume points. Playlists stay. You are asked to confirm first.", ["Settings", "Library", "Profiles"],
          aliases: ["delete a profile", "remove a user", "what happens when i delete a profile"], related: ["setting.profiles"], reach: .settingsPage("Library"), safety: .never, guideOnly: true),
        e(.diagnosis, "diag.viewingBlock", "\"That's enough for today\" or \"It's time to rest\"", "A kids profile used up its daily time, or the clock is inside its night window. Playback comes back when the window ends or tomorrow. A parent can tap Ask a parent and enter the profile's PIN for 30 more minutes (daily limit only).",
          ["Settings", "Library", "Profiles"], aliases: ["kids cant watch", "playback stopped for my kid", "that's enough for today", "its time to rest", "kid blocked from watching", "child timer"], related: ["setting.viewingLimits", "setting.profiles"], reach: .settingsPage("Library"), safety: .never, guideOnly: true),
    ]

    // MARK: Home, Statistics, Tonight

    static let home: [AtlasEntry] = [
        e(.control, "control.statistics.weeklyDigest", "Your week and the Sunday evening notification", "The Your week card on Statistics: time watched, most watched title, new episodes and subscriptions ending, with a switch, Send me this on Sunday evening. It needs notification permission.",
          ["Home", "Statistics", "Your week"], aliases: ["weekly summary", "sunday notification", "send me my watch stats", "weekly digest", "how do i get a weekly viewing summary on sunday", "what is the your week card"], related: ["control.statistics.area"], reach: .shortcut("statistics")),
        e(.control, "control.tonight.usualTime", "Your usual time", "A card on Tonight with what you often put on around the same hour, one tap to play it, and a Remind me ten minutes before button.", ["Home", "Tonight", "Your usual time"],
          aliases: ["what i usually watch at night", "remind me before my show", "usual evening", "tonight card"], reach: .shortcut("tonight")),
        e(.screen, "screen.home.offline", "Offline Home", "With no connection Home says You're offline and shows the downloads that still play. With none saved it tells you to use Download while online.", ["Home"],
          aliases: ["you're offline", "watch without internet", "home says offline", "no internet home", "offline mode"], related: ["recipe.download"], reach: .tab("Home")),
        e(.control, "control.home.clearContinue", "Clear Continue Watching, Recently Watched or Everything", "Each Clear button on Home asks first. Continue Watching forgets only where you stopped; your history and favourites stay. Recently Watched clears that row; Everything clears both.",
          ["Home", "Continue Watching"], aliases: ["forget where i stopped", "wipe my history from home", "clear recently watched", "remove continue watching"], related: ["recipe.continueWatching"], safety: .confirm, guideOnly: true),
        e(.meta, "meta.smartMix", "Smart Mix: how Home picks titles", "Home rows are built on this device from your own library and history: Top This Week, Trending in Your Library, Because You Watched, Rediscover, a row in your preferred language, Fresh Additions, Movie Night (Friday and Saturday evenings), Binge-Worthy Series (weekends), mood rows and genre shelves with All time or This week. Shuffle Recommendations (Shift Command R) re-rolls them and never refreshes playlists. Don't Recommend This keeps a title out.",
          ["Home", "Discover"], aliases: ["why is this recommended", "recommendation", "shuffle recommendations", "because you watched", "rediscover", "movie night", "trending in your library", "for you row", "what is smart mix", "why does home recommend this"],
          detail: "Locked and hidden folders are never used. Weekly trending comes from the details service.", related: ["context.tile.dontRecommend"], reach: .shortcut("discover")),
        e(.control, "control.player.privateBadge", "Private viewing indicator", "While Watch Privately plays, the player says nothing from this is saved: no history, resume point, statistics, lock-screen details or sync. Setu is told only Private viewing.", ["Player"],
          aliases: ["watch privately banner", "nothing is saved", "private mode indicator", "incognito playback"], related: ["recipe.watchPrivately"]),
    ]

    // MARK: about the app, devices, formats

    static let about: [AtlasEntry] = [
        e(.meta, "meta.whatIsStreamSetu", "What StreamSetu is and is not", "StreamSetu is a player for sources you already have: Xtream, M3U, Jellyfin, Emby, Plex, Stalker (Mac), HDHomeRun and other tuners, WebDAV and local files. It provides no channels, playlists or subscriptions. Everything is stored on your device and there is no StreamSetu account.",
          ["About"], aliases: ["what is this app", "does it come with channels", "do you provide iptv", "where do i get channels", "is it legal", "what is streamsetu", "does streamsetu give me channels", "need an account"], related: ["meta.supportedDevices", "meta.pricing"], reach: .modal("about")),
        e(.meta, "meta.pricing", "Price and licence", "The app has no purchase, trial or subscription screen and no StreamSetu account, so I cannot see a price from inside it, and I will not guess one. The licence text is in About under Licenses. For the current price of an app store version, check its store page.",
          ["About", "Licenses"], aliases: ["is it free", "how much does it cost", "kitna paisa", "kitna paisa lagta hai", "any subscription", "is there a trial", "is it open source", "licence", "license", "price", "free or paid"], related: ["screen.settings.advanced.licenses", "meta.whatIsStreamSetu"], reach: .modal("about")),
        e(.meta, "meta.supportedDevices", "Which devices and system versions", "Mac: macOS 14 or later. iPhone and iPad: iOS 18 or later. There are also Android phone and tablet apps, a Fire TV and Android TV app, and a Windows version without the Setu chat. There is no Apple TV app.",
          ["About"], aliases: ["which macos", "does it work on ipad", "android", "fire tv", "windows", "apple tv", "supported devices", "minimum macos", "does it run on my phone", "which ios version"], related: ["meta.differencesByPlatform"], reach: .modal("about")),
        e(.meta, "meta.supportedFormats", "What streams and files play", "Apple's player handles HLS and MP4. The MPV engine adds MKV, raw MPEG-TS, RTSP, DASH, subtitle delay and more audio options. Badges for 4K, HDR, Dolby Vision, Atmos and 5.1 show on title pages. DRM-protected streaming services are only shown through their own website view (Services).",
          ["Settings", "Playback", "Player engine"], aliases: ["does it play mkv", "hevc", "av1", "dolby", "hdr", "rtsp", "dash", "srt", "m3u8", "ts", "drm", "which formats", "supported codecs", "does it support 4k"], related: ["recipe.switchEngine", "diag.engine"], reach: .settingsPage("Playback")),
        e(.meta, "meta.differencesByPlatform", "What is not on every app", "Stalker portals are not on iPhone and iPad. Recording is on Mac, Android and Fire TV only (a weekly repeat is Mac only and the app must be open). Chromecast is Android only; AirPlay is Apple only. iCloud sync is Apple only. Siri Shortcuts are iPhone and iPad. Problem reports are Mac only and off until you turn them on. Audio and subtitle delay need the MPV engine. Catch-up needs your provider's archive. Hindi and Telugu cover the main screens only.",
          ["About"], aliases: ["can i record on iphone", "chromecast", "stalker on ipad", "does ipad have shortcuts", "airplay on android", "what is mac only", "iphone vs mac", "does the iphone app record live tv", "feature differences"], related: ["meta.supportedDevices", "recipe.record"], reach: .modal("about")),
        e(.meta, "meta.compareToOthers", "StreamSetu compared with other apps", "I can only describe what StreamSetu does: a bring-your-own-source player with a TV guide, recording, multi-view and data kept on your device. I cannot speak for other apps, so ask me about a StreamSetu feature and I will explain it.",
          ["About"], aliases: ["better than plex", "difference between streamsetu and tivimate", "vs vlc", "why not use vlc", "compare with other iptv apps", "why use this app"], related: ["meta.whatIsStreamSetu"], reach: .modal("about")),
        e(.meta, "meta.deepLinks", "streamsetu:// links", "The app handles streamsetu:// links for play, watch, open, search, atlas, sleep, add and music. On the Mac use them with Open URL in Shortcuts or scripts (there are no Siri phrases on the Mac). Share Link on a title makes one.",
          ["Help", "Links"], aliases: ["url scheme", "open url shortcut", "streamsetu://", "automation", "stream deck", "add playlist from a link", "deep link"], related: ["recipe.siriShortcuts"]),
        e(.meta, "meta.widgetsAndActivity", "Widgets and Live Activity", "iPhone and iPad have a Continue Watching widget (an iPad widget too) and a Live Activity that shows download progress on the lock screen. They are not on the Mac.", ["Help", "Widgets"],
          aliases: ["home screen widget", "continue watching widget", "download progress lock screen", "live activity"], platforms: [.iPhone, .iPad]),
        e(.shortcut, "shortcut.podcasts.keys", "Podcasts keys", "Option Space plays or pauses the podcast player. On a show page Space plays or pauses and Return plays the focused episode.", ["Keyboard", "Podcasts"],
          aliases: ["podcast play pause key", "podcast keyboard"], platforms: .mac, shortcut: "⌥Space"),
        e(.control, "control.integrations.traktSignIn", "Sign in to Trakt, Save Keys, Remove Keys, Save Token", "Trakt needs your own app Client ID and Secret, then a sign-in. Debrid takes one API token per service. They are kept in the Keychain and Setu never sees them.", ["Settings", "Library", "Trakt"],
          aliases: ["connect trakt", "trakt client secret", "debrid token", "real debrid key"], reach: .settingsPage("Library"), safety: .never, guideOnly: true),
        e(.control, "control.guide.removeGuide", "Add or remove a guide, Guide name", "In Guide sources each added guide has Remove guide, an optional Guide name, the address, and Test and Add.", ["Settings", "Library", "Guide sources"],
          aliases: ["remove xmltv", "name my guide", "delete a guide address"], related: ["setting.guide.addXMLTV"], reach: .settingsPage("Library")),
        e(.control, "control.settings.openNetworkSettings", "Open Network Settings (Local Network)", "Opens System Settings at the Local Network switch, which StreamSetu needs for network sync and finding devices on your Wi-Fi.", ["Settings", "Privacy"],
          aliases: ["local network permission", "lan sync asks for permission", "allow local network"], platforms: .mac, related: ["setting.lanSync"], reach: .settingsPage("Privacy")),
    ]

    // MARK: fixes keyed by what people see

    static let fixes: [AtlasEntry] = [
        e(.diagnosis, "diag.streamingService", "A streaming service page will not open", "The messages map to causes: You're offline (no connection), can't be found (DNS), the secure connection failed (TLS), is taking too long (a timeout), isn't available right now (the site is down), sent this connection to another region (the service chose a regional site), the page stopped responding or couldn't be shown (the page was stopped to protect the app). Use Try Again, Open in Default Browser (Netflix only) or Return to StreamSetu; App DNS or a VPN may help with DNS problems.",
          ["Services"], aliases: ["you're offline", "can't be found", "the secure connection failed", "is taking too long", "isn't available right now", "sent this connection to another region", "the page stopped responding", "couldn't be shown", "netflix wont load", "service page blank"],
          detail: "StreamSetu does not change or hide your location, and whether a service plays video inside the app depends on that service.", platforms: .mac, related: ["screen.services.list", "setting.appDNS", "setting.vpn"]),
        e(.diagnosis, "diag.appLock", "Locked out, or Touch ID fails", "App lock (Settings, Privacy) asks for Touch ID or your Mac password when StreamSetu opens, after sleep and after 30 seconds away. A stream keeps playing; while locked no menu command works. If Touch ID fails, use your Mac password. Setu cannot change app lock.",
          ["Settings", "Privacy", "App lock"], aliases: ["touch id not working", "cant unlock streamsetu", "app asks for password again", "app lock not working", "locked out of the app", "forgot lock"], platforms: .mac, related: ["setting.appLock"], reach: .settingsPage("Privacy"), safety: .never, guideOnly: true),
        e(.diagnosis, "diag.backupRestore", "A restored playlist is off or asks for a login", "A restored playlist comes back switched off and asks for its login, because passwords and full addresses are never exported. Downloads and recordings are not in backups. Switch the playlist on and sign in again.",
          ["Settings", "Library", "Backup"], aliases: ["restore didnt bring my playlists", "restored but nothing plays", "backup failed", "backup not working", "restore asks for password", "playlist off after restore"], related: ["recipe.backupRestore", "diag.sync"], reach: .settingsPage("Library")),
        e(.diagnosis, "diag.proxyDns", "Nothing loads after proxy, App DNS or VPN", "The proxy covers requests and the streams MPV plays, not Apple's player. App DNS cannot fix IP blocking or geography. The VPN pause stops playback if the VPN drops. Switch the setting off to see whether it is the cause. Setu explains these settings but never changes them.",
          ["Settings", "Privacy"], aliases: ["cant connect after enabling proxy", "dns test failed", "proxy not working", "vpn pause stops playback", "nothing loads after vpn"], related: ["setting.proxy", "setting.appDNS", "setting.vpn"], reach: .settingsPage("Privacy"), safety: .never, guideOnly: true),
        e(.diagnosis, "diag.multiviewLimit", "\"Your provider's limit\" alert in Multi-View", "Multi-View warns before opening more streams than your provider allows at once. Open Anyway may make the provider refuse or drop one of the streams.", ["Multi-View"],
          aliases: ["too many connections multi view", "open anyway", "provider limit", "multiview limit alert", "max connections"], platforms: .mac, related: ["screen.multiview", "recipe.multiView"]),
        e(.diagnosis, "diag.libraryRebuilt", "\"Your library was rebuilt\" and the Recovery folder", "The app rebuilt a damaged database and kept your playlists, favourites and history. The old copy is in the Recovery folder, in case you want it.", ["Settings", "Advanced"],
          aliases: ["database could not be read", "everything disappeared after update", "recovery folder", "library was rebuilt", "database corrupted"], related: ["diag.playback"], reach: .settingsPage("Advanced")),
    ]
}
