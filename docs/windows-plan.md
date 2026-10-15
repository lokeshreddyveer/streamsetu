# StreamSetu for Windows: architecture plan

Status: plan only. Nothing is built yet. Decision made: a fully native Windows app.

## Decision

**C# on .NET 8 with WinUI 3 (Windows App SDK), playing video with libmpv.** It looks and behaves like a Windows app: Mica window, native menus, keyboard and touch, media keys, Windows notifications, system dark and light.

The cost is honest and known: this is a third codebase next to the Apple app (Swift) and the Android app (Kotlin). Every rule that exists in both, such as search ranking, More Like This, the parsers and the catalog, has to be written once more in C#. The plan below limits that cost instead of hiding it.

## Two projects, so most of it can be built and tested on a Mac

WinUI only compiles on Windows. Almost nothing else has to. So the code is split:

```
windows/
  StreamSetu.Core/        class library, net8.0: no Windows APIs
  StreamSetu.Core.Tests/  tests that run on a Mac, Linux or Windows with `dotnet test`
  StreamSetu.Windows/     the WinUI 3 app: windows, pages, mpv, tray, secure storage
  StreamSetu.Windows.Tests/  interface and player tests; run on Windows only
```

`StreamSetu.Core` holds everything that is plain logic, so it can be written and tested from this Mac:

| Core area | Ported from | Notes |
|---|---|---|
| Models (channel, movie, series, episode, source) | Android `core-model` | Same names and fields |
| Parsers: M3U, Xtream JSON, XMLTV, Stalker, Jellyfin, Emby, Plex, WebDAV, HDHomeRun, TVHeadend, Enigma2 | Android `core-network` and `data` | Same test fixtures: the existing Kotlin and Swift test inputs become shared data files, so all three apps must give the same answer |
| Catalog and search (SQLite, FTS5, smart query, spelling fix) | Mac `SQLiteCatalogRepository`, Android `SearchRepository` | `Microsoft.Data.Sqlite` with FTS5 |
| More Like This ranking | Android `Similarity.kt`, Mac `SimilarTitles.swift` | Same weights and reasons |
| Favourites, lists, history, resume, per-title memory, intro skip | Both | |
| Updates check against the GitHub release | Android `UpdateLogic` | |
| Translations | Android `I18n` tables | Hindi, Telugu, English |

`StreamSetu.Windows` holds only what needs Windows: pages, navigation, the mpv window, Credential Locker for logins (DPAPI), notifications, the tray, file pickers.

## Shared test data keeps three apps honest

Today the Mac and Android each carry their own test fixtures. The new Core tests will read the same files from a top-level `testdata/` folder (playlists, XMLTV, search cases, ranking cases). Android and Mac tests can adopt them over time. When a rule changes, one fixture changes and the three suites say which app drifted.

## Player

**libmpv only.** Direct3D 11 hardware decoding, one engine, the same options already built elsewhere: tracks, timing, speed, go to time, picture tuning, volume boost, A-B loop, OpenSubtitles.

Video and controls in one window is the hardest part, because mpv draws into a native window handle and XAML draws its own surface (the "airspace" problem). Options:

1. **mpv in a child window with the controls in a transparent, borderless overlay window** that follows it. Reliable, and what other desktop players do. Preferred.
2. mpv render API into a swap chain panel inside XAML, so controls are normal XAML on top. Cleaner and better looking, harder to keep smooth.
3. Controls only in a separate window.

**The first task is a spike of 1 and 2 with real controls**, before the rest is built. The result decides the player design.

## Interface

| Area | Plan |
|---|---|
| Shell | `NavigationView` with Home, Live TV, Movies, Series, TV Guide, Search, Libraries, Settings, like the Mac sidebar |
| Home and lists | Banner and poster rows, virtualized grids (`ItemsRepeater` or `GridView`) |
| Live TV | Folders, channel list, guide grid |
| Player | Fullscreen and windowed, mouse, keyboard, media keys, Windows media overlay (SMTC) |
| Settings | Same groups as the other apps |
| Theme | StreamSetu cyan and gold, system dark and light, high contrast respected |
| Accessibility | UI Automation names on every control; keyboard navigation everywhere |

## Packaging, signing and updates

- **MSIX** installer, built from the project, with an automatic dependency on the Windows App Runtime.
- **Signing is required** for installs without warnings. Microsoft Trusted Signing or a standard code-signing certificate; either needs identity verification that can take days. Arrange it early.
- **Distribution:** direct download from the single release first; Microsoft Store later (it signs for you and updates the app, at the price of a Store review).
- **Updates:** a check against the release, with SHA-256, plus an App Installer file for MSIX when distributed directly.

## Tooling and what I can and cannot do from this Mac

| Task | Here | Needs Windows |
|---|---|---|
| Write all C# | yes | |
| Build and test `StreamSetu.Core` | yes, once the .NET 8 SDK is installed (`brew install dotnet`) | |
| Build the WinUI app, run it, test the player | | **yes**: Windows 10 or 11, Visual Studio 2022 with the Windows App SDK workload |
| GitHub Actions `windows-latest` build, tests and MSIX | I can write the workflow; it runs in the cloud | |
| Judging how it looks and feels | | **yes** |

Without a Windows machine I can write and unit-test all the logic here and let GitHub's Windows runner prove the app compiles, but I could not see it or play a stream. A real Windows PC is needed for the player spike and every interface check.

## Phases

| Phase | Goal | Done when |
|---|---|---|
| 0. Spike (needs Windows) | mpv plays a stream with controls over it | Smooth 1080p, live seek bar, a menu on top, in both overlay designs |
| 1. Core | Models, parsers, catalog, search, sources, shared test data | `dotnet test` passes on the Mac and in CI; fixtures match the Android and Mac results |
| 2. App shell | Window, navigation, add a playlist, Live TV, Movies, Series | A real Xtream login browses and plays |
| 3. Full player and lists | Every shared player option, favourites, history, collections, backup | Feature list passes on Windows 10 and 11 |
| 4. Polish and release | Accessibility, Hindi and Telugu, MSIX, signing, updates | A signed installer upgrades over the last one and keeps data |

Later: Multi-View, reminders as Windows notifications, casting, a Store listing.

## Risks

| Risk | Plan |
|---|---|
| Player overlay (airspace) | Phase 0 spike, before anything depends on it |
| Three codebases drift | Shared `testdata/`, and new logic written in the same shape in all three |
| libmpv licence | The chosen Windows build must be checked: builds with GPL parts make the app GPL. The Mac was flagged the same way. Settle before release |
| No Windows machine here | Needed for Phase 0 and every visual check |
| Code-signing certificate | Apply early |
| WinUI 3 maturity | Pin the Windows App SDK version; keep UI code thin so a bug can be worked around in one place |

## Questions that still need an answer

1. **Do you have a Windows 10 or 11 PC I can use for testing** (you running builds and sending screenshots), or should I plan around GitHub's cloud runner only?
2. Direct download first, or the Microsoft Store from the start?
3. Windows 10 and 11, or 11 only? (Windows 10 support ended in October 2025; supporting it costs little with WinUI 3 but needs testing.)
4. Will you get a code-signing certificate, or do you want to use Microsoft's Trusted Signing?
5. May I install the .NET 8 SDK on this Mac so I can start Phase 1?
