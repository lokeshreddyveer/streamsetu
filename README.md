# StreamSetu

**Your streams. One home.** StreamSetu is a player for the IPTV playlists and media servers you already have: Xtream Codes, M3U links and files, and Stalker/Ministra portals. It includes no channels, movies or subscriptions, and it does not provide any content.

## Download

| Platform | Get it |
|---|---|
| **Mac** | `StreamSetu-x.y.z.dmg` from [Releases](../../releases). Signed and notarized by Apple; updates itself. |
| **Fire TV and Android TV** | `StreamSetu-x.y.z.apk` from [Releases](../../releases). On Fire TV, turn on *Apps from Unknown Sources* and sideload it (for example with Downloader). |
| **iPhone and iPad** | TestFlight. |

## What is in this repository

| Folder | Contents |
|---|---|
| `macos/` | The Mac app (Swift, SwiftUI, AppKit) |
| `ios/` | The iPhone and iPad app (shares most of its code with the Mac app) |
| `android/` | The Fire TV and Android TV app (Kotlin, Jetpack Compose) |
| `web/` | The website |
| `legal/` | Privacy policy and terms |
| `branding/` | App icons and artwork |

The Android app is split into modules (`core-*`, `data`, `app`); see `android/ARCHITECTURE.md` and `android/SPEC-STATUS.md`.

## Build

- **Android:** `cd android && ./gradlew :app:assembleDebug` (JDK 17 and the Android SDK). A signed release build needs your own `android/keystore.properties`; see `android/release.sh`.
- **Mac:** `cd macos && Scripts/run-tests.sh`, then `Scripts/build-release.sh` (needs libmpv in `macos/third_party/`, which is not in this repository).
- **iPhone:** `ios/` is generated into an Xcode project by the scripts in `Scripts/`.

## Privacy

No account, no advertising, no analytics. Connections, favorites and watch progress stay on your device; logins are kept in the system's secure storage. See `legal/`.

## Licence and third-party software

The source is published so it can be read. Unless a licence file says otherwise, all rights in StreamSetu's own code and artwork are reserved by the author. StreamSetu uses third-party software under its own licences, including AndroidX Media3 (Apache 2.0), mpv/libmpv (LGPL 2.1+ / GPL, depending on the build), OkHttp, Coil, Sparkle and others.

Support: contact@lokeshreddy.dev
