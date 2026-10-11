# StreamSetu

A native macOS player for IPTV services you are authorized to use. Swift 6 · SwiftUI · SQLite · AVFoundation.

StreamSetu does not host or distribute content. You add your own M3U playlists or Xtream-compatible logins, and StreamSetu
downloads, normalizes, indexes and caches the catalog **on your Mac** so it opens instantly, searches in milliseconds
and works offline for browsing.

## Features

- **Sources:** M3U (URL or file), M3U8, Xtream-compatible APIs, XMLTV guides — multiple sources at once
- **Live TV:** three-pane layout, now/next per channel, quality-variant grouping, favorites, reminders
- **Movies & Series:** poster browser, on-demand details, seasons/episodes, resume, next-episode
- **TV Guide:** virtualized timeline with a current-time marker and trackpad scrolling
- **Search:** one FTS5 index across live, movies and series — prefix, accent-insensitive, ranked
- **Library:** favorites (drag to order), collections, history, continue watching, Channel Command Center
- **Player:** AVPlayer (with a built-in MPEG-TS→HLS bridge), optional libmpv, PiP, AirPlay, mini-player, fullscreen
- **Live extras:** channel numbers (type to jump), several named favourite lists, sleep timer, radio mode, live rewind, catch-up, multi-view (up to four channels), automatic fallback to another quality variant
- **Per-playlist control:** guide time shift, custom User-Agent and headers, engine and buffering overrides
- **Add anywhere:** drop an M3U file or link on the window, or open a `streamsetu://add?url=…` link; `streamsetu://play?channel=…` and friends for Shortcuts
- **Insight:** viewing statistics (computed locally), artwork and summaries from TMDB with your own API key
- **Look:** 25 themes plus a custom theme editor, 21 accents
- **Private:** no accounts, no server; logins are kept in an encrypted vault bound to this Mac; local automatic backups

## Build

Requires macOS 14+ and Swift 6 (Xcode **or** just the Command Line Tools).

```sh
swift build                       # debug build
Scripts/run-tests.sh              # 300+ tests (uses `swift test` when Xcode is installed)
Scripts/build-release.sh 1.0.0    # dist/StreamSetu.app (universal, ad-hoc signed)
Scripts/create-dmg.sh             # dist/StreamSetu-1.0.0.dmg
Scripts/verify-release.sh         # release checks, including a headless smoke test of the packaged app
```

Open `Package.swift` in Xcode to develop with the full IDE. Signing and notarization are described in
[Docs/RELEASE.md](Docs/RELEASE.md).

## Documentation

[Architecture](Docs/ARCHITECTURE.md) · [Database](Docs/DATABASE.md) · [Source contracts](Docs/SOURCE_CONTRACTS.md) ·
[Playback](Docs/PLAYBACK.md) · [Design system](Docs/DESIGN_SYSTEM.md) · [Security](Docs/SECURITY.md) ·
[Testing](Docs/TESTING.md) · [Release](Docs/RELEASE.md)
