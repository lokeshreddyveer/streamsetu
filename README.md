<p align="center">
  <img src="branding/originals/StreamSetu_FireTV_Landscape_1920x1080.png" alt="StreamSetu: your streams, one home" width="720">
</p>

# StreamSetu

**Your streams. One home.**

StreamSetu is a native player for the IPTV playlists and media servers you already have. It runs on **Mac, iPhone and iPad, Fire TV and Android TV**, keeps everything on your own device, and has no account, no advertising and no analytics.

> StreamSetu is a player only. It provides **no channels, movies, series or subscriptions**, and it does not ship or link to any content. You bring your own legally obtained playlist or login.

## Screenshots

### Mac

<p>
  <img src="docs/screenshots/mac-home.png" alt="StreamSetu on Mac: Home with the Discover banner and Trending in Your Library" width="49%">
  <img src="docs/screenshots/mac-series.png" alt="StreamSetu on Mac: Series with the folder list and poster grid" width="49%">
</p>

### Fire TV and Android TV

<p>
  <img src="docs/screenshots/firetv-home-sidebar.png" alt="StreamSetu on Fire TV: Home with the sidebar open" width="32%">
  <img src="docs/screenshots/firetv-movies.png" alt="StreamSetu on Fire TV: Movies with folders and posters" width="32%">
  <img src="docs/screenshots/firetv-series.png" alt="StreamSetu on Fire TV: Series with a featured banner" width="32%">
</p>

### iPhone

<p>
  <img src="docs/screenshots/ios-home.png" alt="StreamSetu on iPhone: Home" width="24%">
  <img src="docs/screenshots/ios-live.png" alt="StreamSetu on iPhone: Live TV channel grid" width="24%">
  <img src="docs/screenshots/ios-movies.png" alt="StreamSetu on iPhone: Movies" width="24%">
  <img src="docs/screenshots/ios-series.png" alt="StreamSetu on iPhone: Series" width="24%">
</p>

The artwork in these screenshots comes from the provider's own playlist. StreamSetu ships no content.

## Download

| Platform | What to get | Notes |
|---|---|---|
| **Mac** | `StreamSetu-x.y.z.dmg` from [Releases](../../releases) (look for `mac-v…`) | Signed and notarized by Apple. Updates itself. Apple silicon and Intel. |
| **Fire TV, Android TV, Android** | `StreamSetu-FireTV-Android-x.y.z.apk` from [Releases](../../releases) (look for `android-v…`) | One signed APK. Android 5.1 or later. |
| **iPhone and iPad** | TestFlight | Ask for an invitation at contact@lokeshreddy.dev. |

Every download has a SHA-256 checksum in its release notes. Verify it with `shasum -a 256 <file>`.

### Installing on Fire TV

1. On the Fire TV: **Settings → My Fire TV → Developer options**, then turn on **Install unknown apps** for the app you will use to download (for example Downloader).
2. Open that app, enter the APK's address from the Releases page, and install.
3. Open StreamSetu from **Your Apps & Channels**.

If you installed an earlier test build, uninstall it first: test builds before 0.5.0 were signed with a different key, and Android will not install an update signed with another key.

## What it does

### Connect your own sources

- **Xtream Codes**: server, user name and password.
- **M3U playlists**: a web link, or a file from the device or a USB drive.
- **Stalker / Ministra portals** (Fire TV and Android TV): portal address and the MAC address of the box it should act as. Live TV only for now.
- A **custom User-Agent** per connection, for providers that insist on a particular player.
- **Combined libraries**: several connections shown as one library, without copying anything. A title that exists in two connections is one title to you; you choose which connection plays it.
- **Test before you save**: a connection is tried once, by hand, with no automatic retries. A login that works but returns nothing is rejected, and an unfinished setup is kept as a draft you can come back to.
- **Phone setup** (Fire TV): scan a QR code, type the connection on your phone, approve it on the TV. The link works for five minutes, on your home network only.

### Watch

- **Live TV** with channel groups, channel numbers, a three-column browser (folders, channels, live picture), fullscreen, last-channel recall, and typing a channel number.
- **TV Guide** from XMLTV: a timeline grid, programme details, a "now" line, and matching by the provider's guide id or by channel name when ids are missing. A time shift for providers whose guide runs early or late.
- **Catch-up** for channels where the provider offers an archive.
- **Movies and series** with fullscreen detail pages, story and cast from the provider, seasons and episodes, resume, "Start over", "Up next", and a "Continue Forward" or "Catch Up" choice when you skipped an episode. Autoplay never runs across a missing episode.
- **Radio**: stations marked `radio="true"` (or in a Radio category) play with an audio-only screen.
- **Resume anywhere**: progress is saved only after a picture has really played, and a failed seek can never overwrite your earlier position.

### Find things fast

- **Folders** are the provider's own categories. You can search them, favorite, pin, reorder (up, down, first, last), hide, lock behind a PIN, give them a display name, and reset any of it. Nothing you do changes the provider's playlist; it is all stored on your device.
- **Collections** of your own, and a shortcut row for Favorites, Watch Later, Recently Watched and Continue Watching.
- **Search** runs on a local text index, so it works offline: prefix matching, accents and case ignored, typo-tolerant ranking, recent searches.
- **Sorting** only offers orders the catalog can truly support (recently added, A–Z, release year, rating, recently watched, new episodes first…), remembered per section and per folder.

### Playback you can trust

- **Two engines**: Media3 ExoPlayer for HLS, MP4, DASH and MPEG-TS, and mpv for MKV, AVI and unusual formats. Automatic chooses per stream; if a format fails it tries the other engine once. Switching engine retries the *same* stream; a different provider stream is only ever your choice.
- **Recovery**: a stream stuck loading is treated as failed; failures are sorted into network, login, copy-protection, decoder and format problems, and only the relevant action is offered.
- **One-connection providers** are respected: a new stream waits for the old one to close.
- **Separate buffering** for Live TV and for movies, with per-connection overrides.
- **Stream details** on screen: engine, resolution, codecs, buffer, dropped frames.

### Built for the remote

- Everything works with a Fire TV remote: arrows, OK, **hold OK for a menu**, Back, and digits.
- Back always goes one step up: close a menu → leave a page → folders → sidebar → Home → library chooser.
- Smooth, restrained motion with one shared set of timings; reduced-motion is respected.
- Optional soft **interface sounds** (original tones, off by default during playback volume rules, never touching the TV's volume).

### Privacy and safety

- No account, no advertising, no analytics, no crash reporting sent anywhere.
- Logins live in the system's secure storage (Android Keystore, Apple Keychain) and are never shown, logged or exported.
- Diagnostic reports and backups remove addresses, user names, passwords and tokens.
- Folder locks are a real PIN lock: the PIN is stored only as a salted hash, and locked titles are also left out of search and banners.
- Backups hold favorites, folder arrangements, progress and settings, never logins or playlist links.

## Platforms and compatibility

| | Mac | iPhone and iPad | Fire TV / Android TV |
|---|---|---|---|
| Language | Swift, SwiftUI, AppKit | Swift, SwiftUI | Kotlin, Jetpack Compose |
| Engines | AVPlayer + mpv | AVPlayer + mpv | Media3 ExoPlayer + mpv |
| Connections | Xtream, M3U, Stalker, local media, WebDAV/SMB | Xtream, M3U, Stalker, Files | Xtream, M3U, local M3U, Stalker (live) |
| Minimum | macOS 14 | iOS 17 | Android 5.1 (mpv needs Android 8) |

The Fire TV app has been developed and tested on a Fire TV Stick 4K (Fire OS 7). Other devices should work but have not all been tested.

## Repository layout

| Folder | Contents |
|---|---|
| `macos/` | The Mac app and the release scripts (build, sign, notarize, publish, update feed) |
| `ios/` | The iPhone and iPad app (shares most code with the Mac app) |
| `android/` | The Fire TV and Android TV app |
| `web/` | The website and privacy pages |
| `legal/` | Privacy policy and terms |
| `branding/` | Icons and artwork |

### Android modules

```
core-model        data classes, sorting and capability models
core-security     Android Keystore credential store
core-network      HTTP client, M3U / Xtream / XMLTV parsers
core-database     Room database (v5) plus the text-search index
core-preferences  settings and appearance preferences
core-media        playback coordinator, ExoPlayer and mpv engines, recovery policy
core-ui           shared motion timings, reduced-motion handling
data              repositories, sync, EPG, search, Stalker client, backup and maintenance
app               Hilt wiring, navigation, all screens, interface sounds
```

More detail is in [`android/ARCHITECTURE.md`](android/ARCHITECTURE.md), and what is built against each specification is in [`android/SPEC-STATUS.md`](android/SPEC-STATUS.md).

## Building

| Target | Command | Needs |
|---|---|---|
| Android (debug) | `cd android && ./gradlew :app:assembleDebug` | JDK 17, Android SDK |
| Android (tests) | `./gradlew :data:testDebugUnitTest :core-media:testDebugUnitTest :app:testDebugUnitTest` | same |
| Android (signed release) | `cd android && ./release.sh 1.0.0 12` | your own `android/keystore.properties` (storeFile, storePassword, keyAlias, keyPassword). Without it the APK is debug-signed and for testing only. |
| Mac (tests) | `cd macos && Scripts/run-tests.sh` | Xcode command line tools |
| Mac (release) | `cd macos && Scripts/build-release.sh` | libmpv in `macos/third_party/` (not in this repository), a Developer ID certificate, a notarization profile |
| iPhone | scripts in `Scripts/` generate the Xcode project | Xcode, an Apple developer account for devices |

## Known limits

- Stalker portals: live TV only; no movies, series or guide from a portal yet.
- Refresh-rate matching, audio delay and subtitle delay are not offered on Fire TV.
- Catch-up needs a provider that offers an archive, and some providers read the start time in their own time zone (there is a setting for it).
- The Fire TV app is newer than the Mac and iPhone apps and has had less testing on real devices.

## Support and feedback

contact@lokeshreddy.dev. A diagnostic report (Settings → Diagnostics) contains no logins or provider addresses and is safe to attach.

## Licence and third-party software

The source is published so it can be read. Unless a licence file says otherwise, all rights in StreamSetu's own code and artwork are reserved by the author. StreamSetu uses third-party software under its own licences, including AndroidX Media3 (Apache 2.0), mpv/libmpv (LGPL 2.1 or later, GPL in some builds), OkHttp, Retrofit, Coil, Hilt, Room, ZXing and Sparkle.
