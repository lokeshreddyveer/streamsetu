# StreamSetu for Android TV and Fire TV

A native Kotlin app for Android TV, Google TV and Amazon Fire TV (Fire OS 5 and later, API 22+). It mirrors the Apple apps' ideas:
playlists in, one catalogue, one player with recovery, favourites and history kept on the device. No shared code with the Swift apps.

## Layout

```
android/
  core/   Android library, no UI. Everything that is not a screen.
  app/    The TV interface (Jetpack Compose) and the Activity.
```

### core
| Package | Role |
|---|---|
| `model` | Plain data classes: `Source`, `Channel`, `Movie`, `Series`, `Episode`, `EpgProgram`, `WatchProgress`, and the `Playable` family the player takes. |
| `parse` | `M3uParser` (streaming, tolerant), `Xtream` (addresses and lenient JSON reading), `XmltvParser` (guide, pull parser). Pure logic, unit tested. |
| `data.db` | Room database: entities, DAOs, `AppDatabase`. One table per kind, indices for category and search. |
| `data.repo` | `SourceRepository`, `CatalogRepository`, `UserRepository` (favourites, Watch Later, resume positions, play log, most-watched). The only way screens read data; all reads are `Flow`. |
| `sync` | `SyncService` reads a playlist into the database in one transaction (old rows are replaced only after the new ones were read). `EpgService` keeps a 48-hour guide window. |
| `net` | `Http` (one OkHttp client), `StreamResolver` (turns a stored reference into a playable address; Xtream logins are applied only here). |
| `security` | `CredentialStore` with an Android Keystore (AES-GCM) implementation. Passwords never reach the database or logs. |
| `playback` | `PlaybackController` (Media3 ExoPlayer, one instance), `PlaybackState`, and `RecoveryPolicy` (pure retry/back-off rules: live streams retried more than movies, refusals explained, waits for the network). |

### app
| Piece | Role |
|---|---|
| `StreamSetuApp` / `AppContainer` | Object graph built once; no DI framework. |
| `MainActivity` | Side rail, tab content, overlays, back handling. |
| `nav.Navigator` | Tabs (Home, Live TV, Movies, Series, Search, Settings) and overlays (player, add playlist, series detail). Back closes the top overlay, then returns to Home, then leaves. |
| `ui.screens` | One file per area. ViewModels expose `StateFlow`s built from the repositories. |
| `ui.components` | `Focusable` (focus ring + scale; everything the remote can land on), `PosterCard`, `TvButton`, `TvTextField`, `SideRail`. |
| `ui.theme.Tokens` | Colours and sizes. Same near-black / cyan / blue look as iPhone and Mac. Text is never below 14 sp (read from a sofa). |

## Data flow
```
playlist ──SyncService──▶ Room ──DAO Flow──▶ Repository ──▶ ViewModel StateFlow ──▶ Compose
remote OK ─▶ AppContainer.play(item, queue) ─▶ StreamResolver ─▶ PlaybackController ─▶ ExoPlayer
                                           └▶ UserRepository (play log, resume positions every 10 s)
```

## Playback rules (same priorities as the Apple apps)
* One player instance. Switching channel stops reading the old stream before the new one starts.
* Failure → `RecoveryPolicy` decides: retry with growing waits (1, 2, 4, 8, 15 s), or stop with a plain message.
  A 401/403/429/5xx is treated as "provider refused" (often a one-connection limit): two tries, then explained.
* No network → the player waits and resumes by itself when a network returns.
* Movies and episodes resume where they stopped; within 30 s of the end (or 95 %) counts as watched.
* Buffer: starts after 1.5 s of data, holds up to 60 s.

## Remote control
OK shows the bar (and pauses a movie when the bar is already visible). Left/Right skip 10 s in a movie. Up/Down change channel in a live list
(and step episodes in a series). Play/pause and fast-forward/rewind media keys work. Back closes the player.

## Mac parity (what was copied from the macOS app)
* **Layout:** top bar with Home, Live TV, Movies, Series, TV Guide, plus Search and Settings; a contextual sidebar per section with the Mac's pinned shortcuts
  (Discover, Continue Watching, Recently Watched, Watch History, Favorites, Watch Later, Featured, All Movies, Recently Added, All Channels…) and a "Folders" list below.
* **Design:** the Obsidian palette and the Mac's radii; flat cards with a thin accent ring only while focused; coral Play pill; Discover banner with "DISCOVER · FROM YOUR LIBRARY".
* **Engines:** `PlayerEngine` with `ExoEngine` and `MpvEngine` (libmpv), `EngineSelector` (Automatic / ExoPlayer / MPV, same rules as the Mac), switch to the other engine once on a
  format failure, retry policy, buffering modes (Automatic, Low latency, Standard, Large), resume and "play next episode automatically".
* **Settings:** General, Playback, Library, Advanced pages with grouped rows; every control saves at once (`AppSettings`).
* **Navigation:** tabs and sidebar entries show their content as focus rests on them; Back goes up to the top bar first; focus is remembered per list.

## Player (matches the iPhone app)
Chips under the progress bar: Audio, Subtitles, Speed, Picture (Fit / Fill / Zoom), Player (ExoPlayer / MPV for this stream), Start over (after a resume), Channels (live), More
(sleep timer, favourite, last channel, stream information, Picture in Picture). Live: channel banner with now/next, ▲ ▼ channel, ◀ channel list, digits type a channel number.
Movies: ◀ ▶ skip 10 s, ▼ options, "Up next" card in the last 30 s of an episode. A failed stream offers Try Again / Next Channel / Close.

## Reliability rules (from the Fire TV architecture brief)
- Progress is written only for the session still playing, after a picture has really shown, with sane numbers; a position far below the resume point (a failed seek) never replaces the earlier checkpoint unless the person seeked.
- Add Playlist is one explicit **Test and Save**: no automatic retries, an empty catalog counts as a failure (nothing is kept), success shows a summary (channels / movies / series) before Home opens.
- Engine fallback changes the player, never the provider stream; there is no silent switch to another source.
- Not built yet: library chooser at launch / combined libraries (the app merges all playlists), drafts, QR phone setup, catch-up, source variants.

## Engine robustness
ExoPlayer: transport-stream flags for streams cut mid-frame, decoder fallback, live-window recovery, buffer modes. MPV: reconnect on network errors, short probe for live. The controller
treats a stream stuck in buffering as a failure (18 s live, 30 s movies) so retry and engine-switch rules take over, logs the time to first picture, and spaces streams on one-connection accounts.

## Provider behaviour learned from a real account
* Xtream accounts say which live formats they allow (`allowed_output_formats`). Many allow only `ts`; asking for `m3u8` is refused. `StreamResolver` follows the account.
* Playlists contain divider rows ("#### Bulgaria ####") that are not streams; they are dropped at sync.

## Verified on a Fire TV Stick 4K (AFTKM, Fire OS 7) with a real Xtream account
Live TV (MPEG-TS) on ExoPlayer and MPV, movies (MP4) on both, series episodes, engine fallback, add-playlist with the on-screen keyboard, focus and back navigation.

## Not built yet
1. Catch-up playback and a time-grid guide.
2. PIN protection for the adult switch.
3. Stalker portals, HDHomeRun, local files and WebDAV.
4. Subtitle styling settings; the aspect ratio / zoom controls of the Mac player.
5. Secure-DNS fallback for blocked server names (done on Apple; same idea fits `StreamResolver`).
6. Amazon Appstore listing; sideload the APK until then.

## Build and test
```
export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :core:testDebugUnitTest      # parsers and recovery policy
./gradlew :app:assembleDebug           # app/build/outputs/apk/debug/app-debug.apk
adb connect <fire-tv-ip>:5555 && adb install -r app/build/outputs/apk/debug/app-debug.apk
```
On a Fire TV: Settings → My Fire TV → Developer Options → ADB debugging (and Apps from unknown sources) → on.

## Verification status
Unit tests: parsers, retry policy, parental words, divider rows, live-format choice.
