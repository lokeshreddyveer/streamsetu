import Foundation

/// What is new in the current release, written by hand from docs/releases/2026.11.23.md (Mac 2.18.0, iPhone and iPad 1.4 build 79, Android and Fire TV 0.27.0).
/// Update this file and `meta.whatsNew` (Recipes.swift) when a release note is added; the older generator script no longer feeds it.
enum AtlasWhatsNew {
    private static let path = ["About", "What's new"]

    static let all: [AtlasEntry] = [
        .make("meta.whatsNew.2026.11.23", .meta, "New in Mac 2.18.0 and iPhone and iPad 1.4", "Title pages reworked for movies and series, genre shelves on Home and Browse with an All time or This week switch, stars on every tile from one shared rating rule, better matching of titles to artwork, four online artwork and details sources, and search fixes.",
              path: path, reach: .modal("about"), aliases: ["2.18", "mac 2.18.0", "ios 1.4", "build 79", "latest release", "november 23", "title pages", "genre shelves", "stars on tiles", "matcher"],
              detail: "The details service (TMDB) works out of the box with a key built into the app, and you can still add your own or turn it off in Settings, Artwork and Details. Only ids go to the artwork, episode-data and schedule services, never your history, lists or folder names, and locked or hidden folders are never sent. Smoother scrolling on every app.",
              related: ["meta.whatsNew", "meta.whatsNew.2026.11.23.mac", "meta.whatsNew.2026.11.23.ios"], since: "2.18.0", reviewed: true),
        .make("meta.whatsNew.2026.11.23.mac", .meta, "New in Mac 2.18.0: streaming services inside the app", "A Services menu (pin it to the top bar) opens a streaming service's own website inside StreamSetu, each with its own icon and its own card and Clear Data button in Settings. Screens are kept when you switch tabs, so scroll position, filters, sort and search text stay as you left them.",
              path: path, reach: .modal("about"), aliases: ["services inside the app", "streaming services", "services menu", "page options", "smoother scrolling", "faster screens"],
              detail: "Page options (skipping a service's video ads and community-marked sponsor segments) exist for one service, are off by default, and the app asks first and explains the risks. If a service does not load, a message says why. Mac only.",
              platforms: .mac, related: ["screen.services.list", "meta.whatsNew"], since: "2.18.0", reviewed: true),
        .make("meta.whatsNew.2026.11.23.ios", .meta, "New in iPhone and iPad 1.4: the Setu assistant", "The Setu chat button at the bottom right of the main screens answers questions about the app. It is hidden in kids mode and sends nothing online until you choose a provider and key; Apple Intelligence runs on the device.",
              path: path, reach: .modal("about"), aliases: ["setu on iphone", "assistant on ipad", "chat button", "ios 1.4 setu"],
              platforms: [.iPhone, .iPad], related: ["screen.assistant", "meta.whatsNew"], since: "1.4", reviewed: true),
        .make("meta.whatsNew.music", .meta, "New in the Mac app: Music", "Music (command 8, or Music in the top bar) is a full player inside StreamSetu: a personal Listen Now, a regional Explore with country charts, search, Your Library, Radio, Downloads, Devices and Listen Together, lyrics, an equalizer and a floating player bar. There is no toolbar; a Back pill and a round side-panel button replace it.",
              path: path, reach: .destination("music"), aliases: ["music is new", "what is music", "new music shell", "music redesign", "listen now", "music in streamsetu"],
              detail: "Sources are your own and the open ones you switch on in Music, Settings, Plugins & Sources. Music is on the Mac only and is not offered in a kids profile or while the app is locked.",
              platforms: .mac, related: ["screen.destination.music", "screen.music.sidePanel", "control.music.backPill"], reviewed: true),
    ]
}
