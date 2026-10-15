# StreamSetu for Windows: architecture plan

Status: plan only. Nothing is built yet.

## Decision

Build the Windows app in **Kotlin with Compose Multiplatform for Desktop**, sharing the Android app's logic, and play video with **libmpv**.

Why this and not the alternatives:

| Option | Reuse | Fit for Windows | Cost |
|---|---|---|---|
| **Kotlin + Compose Desktop (chosen)** | The Android catalog, parsing, search, sources and UI building blocks | Good. Installer, tray, keyboard and mouse all work | Medium |
| WinUI 3 with C# | None. Every rule is written a third time | Best look and Store fit | High, and every later feature is built three times |
| Tauri or Electron | Little | Heavy runtime; video in a web view is the weak spot for IPTV | Medium |
| Swift on Windows | Mac code is Swift, but SwiftUI does not run on Windows | Not usable for the interface | High |

The Android app is the newest and most complete code, and its logic modules are already close to plain Kotlin. Counted from the source today: `core-model` and `core-network` have no Android imports; `data` has 28 files, 6 of which touch Android.

## Layers

```
windows/
  app            Compose Desktop interface (new): window, navigation, screens
  player         libmpv wrapper (new): load, seek, tracks, delay, picture options
  platform       Windows services (new): secure storage, file dialogs, tray, updates
shared (taken out of android/ into plain Kotlin/JVM modules)
  core-model     titles, channels, episodes
  core-network   HTTP, XMLTV, M3U, Xtream, Stalker, Jellyfin, Emby, Plex, WebDAV
  data           catalog, search, similarity, favourites, history, sync
  core-ui-kit    components that do not depend on Android (posters, rows, chips)
```

The Android modules keep working: they depend on the shared modules, and nothing in `android/` changes behaviour.

## What each piece becomes

| Need | Android today | Windows |
|---|---|---|
| Database | Room | The same schema and SQL on SQLite (Room's Kotlin Multiplatform release, or SQLDelight). Search keeps its FTS index |
| Logins | Android Keystore | Windows Credential Manager (DPAPI), through JNA |
| Player | ExoPlayer and MPV | **MPV only**, with Direct3D 11 hardware decoding. One engine means fewer surprises |
| Settings | SharedPreferences | A small file in the user's AppData |
| Background refresh | WorkManager | Refresh on open and on a timer while the app runs; a tray icon keeps it available |
| Updates | GitHub release check | Same check against the repository's release (an `.msi` or `.msix` in release `2026.xx.xx`), with the SHA-256 shown |
| Layout | Remote and touch | Window with mouse, keyboard, and trackpad; resizable; fullscreen player |
| Language | Hindi, Telugu, English tables | The same tables |

## The hard part: video and controls in one window

MPV draws into a native window handle. A Compose interface cannot normally draw on top of a native video surface (the "airspace" problem). Options, in order of preference:

1. Give mpv a child window and put the controls in a second, transparent, borderless window that follows it. Reliable, and is how several desktop players do it.
2. Render mpv into an OpenGL texture with its render API and draw the picture inside Compose. Cleaner, but more code and harder to keep smooth.
3. A native overlay for controls only.

**First task is a spike to prove option 1** with the real controls (pause, seek bar, audio and subtitle menus, search) before anything else is built.

## Features for the first release

Parity with what the other apps do best, in this order:
1. Add a playlist (Xtream, M3U link or file, Stalker, Jellyfin, Emby, Plex, WebDAV) with a connection test.
2. Live TV with groups, the guide, and favourites.
3. Movies and series with resume, More Like This, and search (including search inside the player).
4. The player options already shared everywhere: tracks, timing, speed, go to time, Skip Intro, remembered choices, OpenSubtitles, picture tuning, volume boost, stats.
5. Folders, lists, collections, history, backup and restore.
6. Hindi and Telugu.

Later: Multi-View, reminders (Windows notifications), casting, SMTC media keys and the system volume overlay.

## Phases

| Phase | Goal | Done when |
|---|---|---|
| 0. Spike | mpv plays a stream with controls over it in a Compose window | Smooth playback at 1080p with a live seek bar and a menu on top |
| 1. Shared code | Move the logic modules out of Android without changing Android | Android builds and every Android test still passes; the same modules compile for the JVM |
| 2. Core app | Add a playlist, browse, play | A real Xtream login shows channels, movies and series and plays them |
| 3. Full player and lists | The features above | Feature list passes on a Windows 10 and a Windows 11 machine |
| 4. Release | Installer, signing, updates | A signed installer upgrades over the previous one and keeps data |

## Packaging, signing and updates

- Installer: `jpackage` builds an `.msi` (or `.msix`). The app ships its own runtime, so users install nothing else.
- Signing: Windows shows a warning for unsigned installers. A code-signing certificate is needed (Microsoft's Trusted Signing service or a standard certificate); this is a cost and an identity check to arrange before the first public build.
- Distribution: direct download from the release, as for the other apps. The Microsoft Store can come later.
- Updates: in-app check against the release, like Android.

## Tests

- The shared modules keep their existing unit tests and run them on the JVM.
- New: player wrapper tests with a fake mpv, a database test on Windows paths, and a smoke test that starts the app and opens a local test stream.
- GitHub Actions gets a `windows-latest` job that builds, tests and produces the installer.

## Risks

| Risk | Plan |
|---|---|
| Controls over the video | The Phase 0 spike decides this before more is built |
| libmpv licence: builds are GPL unless built without GPL parts | Check the licence of the build chosen, as was flagged for the Mac. Settle before release |
| Windows needs its own real-device testing | Test on a Windows 10 and a Windows 11 machine; I cannot do this from a Mac |
| A fourth implementation of every new feature | Put new logic in the shared modules first; only the interface is Windows-specific |
| Code-signing certificate | Arrange it early; it can take days to verify an identity |

## Questions for you

1. Is Kotlin with Compose Desktop acceptable, or do you prefer a fully native WinUI 3 app (more polish on Windows, but three codebases)?
2. Direct download first, or the Microsoft Store from the start?
3. Windows 10 and 11, or 11 only?
4. Do you have, or are you willing to get, a code-signing certificate?
5. A Windows machine to test on: yours, or a virtual machine on this Mac (slower, no real GPU)?
